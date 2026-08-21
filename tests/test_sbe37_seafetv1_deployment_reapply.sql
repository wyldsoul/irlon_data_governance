\set ON_ERROR_STOP on
-- PostgreSQL 12 disposable deployment test.  It exercises the explicit clean
-- and upgrade entry points in public, preserving representative registry data
-- while module functions/triggers are reapplied twice.

CREATE TABLE seabird_sbeeco (
  station varchar NOT NULL, m_date timestamptz NOT NULL, instrument varchar,
  conductivity double precision, qc_conductivity integer, salinity double precision, qc_salinity integer,
  temperature_water double precision, qc_temperature_water integer, pressure_water double precision, qc_pressure_water integer,
  depth_instrument double precision, qc_depth_instrument integer, oxygen_saturation_perc double precision, qc_oxygen_saturation_perc integer,
  dissolved_oxygen double precision, qc_dissolved_oxygen integer, specific_conductance double precision, qc_specific_conductance integer,
  UNIQUE (station, m_date));
CREATE TABLE seabird_sbe37 (
  station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_sbe37 varchar,
  raw_conductivity_hz double precision, row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  UNIQUE (station,m_date));
CREATE TABLE seabird_seafetv1 (
  station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_seafet varchar,
  ph_tempsal double precision, qc_ph_tempsal integer, ph_int double precision,
  row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, UNIQUE(station,m_date));

\ir ../sql/deploy_sbe37_seafetv1_clean.sql

INSERT INTO seabird_seafetv1 VALUES
  ('_IRL-UP_SEAFETV1','2026-05-01 00:00+00','UP-1',NULL,NULL,7.9),
  ('IRL-UP-WQ','2026-05-01 00:00+00',NULL,8.1,3,NULL);
INSERT INTO rejected_observations
  (source_table,source_row_id,public_table,source_station,public_station,instrument_type,
   instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
VALUES ('seabird_seafetv1',(SELECT row_id FROM seabird_seafetv1 WHERE station='_IRL-UP_SEAFETV1'),
        'seabird_seafetv1','_IRL-UP_SEAFETV1','IRL-UP-WQ','SeaFET v1','UP-1',
        '2026-05-01 00:00+00','ph_tempsal',1,'active deployment fixture','tester');
INSERT INTO rejected_observations
  (source_table,source_row_id,public_table,source_station,public_station,instrument_type,
   instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by,
   active,reinstated_at,reinstated_by,reinstatement_reason)
VALUES ('seabird_seafetv1',(SELECT row_id FROM seabird_seafetv1 WHERE station='_IRL-UP_SEAFETV1'),
        'seabird_seafetv1','_IRL-UP_SEAFETV1','IRL-UP-WQ','SeaFET v1','UP-1',
        '2026-05-01 00:00+00','ph_tempsal',2,'inactive deployment fixture','tester',
        false,now(),'reviewer','historical fixture');
CREATE TABLE deployment_reapply_snapshot AS
  SELECT * FROM rejected_observations ORDER BY rejection_id;

\ir ../sql/deploy_sbe37_seafetv1_upgrade.sql
\ir ../sql/deploy_sbe37_seafetv1_upgrade.sql

DO $$
BEGIN
  IF EXISTS (
       (SELECT * FROM rejected_observations
        EXCEPT SELECT * FROM deployment_reapply_snapshot)
       UNION ALL
       (SELECT * FROM deployment_reapply_snapshot
        EXCEPT SELECT * FROM rejected_observations)
  ) THEN
    RAISE EXCEPTION 'registry history or identity changed during module reapply';
  END IF;
  IF (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='rejected_observations'
        AND indexname IN ('rejected_observations_active_source_row_parameter_key',
                          'rejected_observations_active_legacy_parameter_key')) <> 2 THEN
    RAISE EXCEPTION 'registry identity indexes were duplicated or lost';
  END IF;
  IF (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE NOT t.tgisinternal AND n.nspname='public'
        AND t.tgname IN ('sbe37_guard_rejected_public_parameters','sbe37_reapply_rejected_public_parameters',
                         'seafetv1_guard_rejected_public_parameters','seafetv1_reapply_rejected_public_parameters')) <> 4 THEN
    RAISE EXCEPTION 'governance triggers were duplicated or lost during reapply';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace
        AND proname IN ('sbe37_public_station','sbe37_source_station','sbe37_set_public_write_identity',
                        'sbe37_count_active_rejections','sbe37_apply_active_rejections',
                        'reject_sbe37_public_parameter','reinstate_sbe37_public_parameter',
                        'sbe37_create_temperature_dependents','sbe37_create_salinity_dependents',
                        'sbe37_create_pressure_dependents','sbe37_guard_public_parameter_write',
                        'sbe37_reapply_rejections_after_private_write','seafetv1_public_station',
                        'seafetv1_source_station','seafetv1_resolve_serial',
                        'reject_seafetv1_public_parameter','seafetv1_apply_active_rejections',
                        'reinstate_seafetv1_public_parameter','seafetv1_guard_public_parameter_write',
                        'seafetv1_reapply_rejections_after_private_write')) <> 20 THEN
    RAISE EXCEPTION 'governance functions were duplicated or lost during reapply';
  END IF;
END $$;

UPDATE seabird_seafetv1 SET ph_tempsal=8.2,qc_ph_tempsal=3
 WHERE station='IRL-UP-WQ' AND m_date='2026-05-01 00:00+00';
DO $$
BEGIN
  IF (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-UP-WQ') IS NOT NULL
     OR (SELECT qc_ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-UP-WQ') <> 1 THEN
    RAISE EXCEPTION 'active SeaFET rejection was not enforced after module reapply';
  END IF;
END $$;
