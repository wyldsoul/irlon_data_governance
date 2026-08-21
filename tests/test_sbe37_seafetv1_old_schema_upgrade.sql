\set ON_ERROR_STOP on
-- Run only after test_sbe37_seafetv1_old_schema_fixture.sql and the two SQL
-- files materialized with `git show HEAD:<path>` have installed the committed
-- pre-hardening deployment.  This deliberately proves the upgrade path from
-- the repository baseline rather than from the new clean-install wrapper.

INSERT INTO seabird_sbeeco VALUES
 ('IRL-OLD-A-WQ','2026-06-01 00:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3),
 ('IRL-OLD-I-WQ','2026-06-01 01:00+00','SBE37/ECO',5,3,31,3,21,3,1,3,1,3,91,3,9,3,4001,3),
 ('IRL-OLD-T-WQ','2026-06-01 02:00+00','SBE37/ECO',6,3,32,3,22,3,1,3,1,3,92,3,10,3,4002,3),
 ('IRL-OLD-BAD-WQ','2026-06-01 04:00+00','SBE37/ECO',7,3,33,3,23,3,1,3,1,3,93,3,11,3,4003,3);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz) VALUES
 ('_IRL-OLD-A_SBE37','2026-06-01 00:00+00','OLD-A',4000),
 ('_IRL-OLD-I_SBE37','2026-06-01 01:00+00','OLD-I',4001),
 ('_IRL-OLD-T_SBE37','2026-06-01 02:00+00','OLD-T',4002),
 ('_IRL-OLD-BAD_SBE37','2026-06-01 04:00+00','OLD-BAD',4003);
INSERT INTO seabird_seafetv1 VALUES
 ('_IRL-OLD-T_SEAFETV1','2026-06-01 02:00+00','OLD-T-SF',NULL,NULL,7.9),
 ('IRL-OLD-T-WQ','2026-06-01 02:00+00',NULL,8.1,3,NULL),
 ('_IRL-OLD-SF_SEAFETV1','2026-06-01 03:00+00','OLD-SF',NULL,NULL,7.8),
 ('IRL-OLD-SF-WQ','2026-06-01 03:00+00',NULL,8.0,3,NULL);

SELECT reject_sbe37_public_parameter('_IRL-OLD-A_SBE37','OLD-A','2026-06-01 00:00+00','conductivity',1,'old active','tester');
SELECT reject_sbe37_public_parameter('_IRL-OLD-I_SBE37','OLD-I','2026-06-01 01:00+00','conductivity',2,'old inactive','tester');
SELECT reinstate_sbe37_public_parameter((SELECT rejection_id FROM rejected_observations WHERE source_station='_IRL-OLD-I_SBE37'),'reviewer','old reinstatement');
SELECT reject_seafetv1_public_parameter('_IRL-OLD-SF_SEAFETV1','OLD-SF','2026-06-01 03:00+00','ph_tempsal',2,'old SeaFET active','tester');
SELECT reject_sbe37_public_parameter('_IRL-OLD-T_SBE37','OLD-T','2026-06-01 02:00+00','temperature_water',1,'old dependency tree','tester');

CREATE TABLE old_schema_upgrade_snapshot AS
 SELECT rejection_id,source_table,source_row_id,public_parameter,active,parent_rejection_id,
        rejected_at,reinstated_at,reinstated_by,reinstatement_reason
   FROM rejected_observations ORDER BY rejection_id;

\ir ../sql/deploy_sbe37_seafetv1_upgrade.sql
\ir ../sql/deploy_sbe37_seafetv1_upgrade.sql

DO $$
DECLARE v_parent bigint; v_child bigint; v_allowed boolean;
BEGIN
  IF EXISTS ((SELECT * FROM old_schema_upgrade_snapshot
                EXCEPT SELECT rejection_id,source_table,source_row_id,public_parameter,active,parent_rejection_id,
                              rejected_at,reinstated_at,reinstated_by,reinstatement_reason FROM rejected_observations)
             UNION ALL
            (SELECT rejection_id,source_table,source_row_id,public_parameter,active,parent_rejection_id,
                    rejected_at,reinstated_at,reinstated_by,reinstatement_reason FROM rejected_observations
                EXCEPT SELECT * FROM old_schema_upgrade_snapshot)) THEN
    RAISE EXCEPTION 'old registry rows changed during upgrade';
  END IF;
  IF (SELECT count(*) FROM rejected_observations) <> (SELECT count(*) FROM old_schema_upgrade_snapshot) THEN
    RAISE EXCEPTION 'old registry row count changed during upgrade';
  END IF;
  IF (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='rejected_observations'
        AND indexname IN ('rejected_observations_active_source_row_parameter_key','rejected_observations_active_legacy_parameter_key')) <> 2 THEN
    RAISE EXCEPTION 'registry indexes changed during upgrade';
  END IF;
  IF (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgname IN
        ('sbe37_guard_rejected_public_parameters','sbe37_reapply_rejected_public_parameters',
         'seafetv1_guard_rejected_public_parameters','seafetv1_reapply_rejected_public_parameters')) <> 4 THEN
    RAISE EXCEPTION 'governance triggers changed during upgrade';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN
        ('sbe37_public_station','sbe37_source_station','sbe37_set_public_write_identity','sbe37_count_active_rejections',
         'sbe37_apply_active_rejections','reject_sbe37_public_parameter','reinstate_sbe37_public_parameter',
         'sbe37_create_temperature_dependents','sbe37_create_salinity_dependents','sbe37_create_pressure_dependents',
         'sbe37_guard_public_parameter_write','sbe37_reapply_rejections_after_private_write',
         'seafetv1_public_station','seafetv1_source_station','seafetv1_resolve_serial','reject_seafetv1_public_parameter',
         'seafetv1_apply_active_rejections','reinstate_seafetv1_public_parameter','seafetv1_guard_public_parameter_write',
         'seafetv1_reapply_rejections_after_private_write')) <> 20 THEN
    RAISE EXCEPTION 'governance functions changed during upgrade';
  END IF;
  IF position('unsupported active SBE37 public parameter' in pg_get_functiondef('sbe37_guard_public_parameter_write()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'hardened SBE37 function was not installed';
  END IF;
  v_parent := (SELECT rejection_id FROM rejected_observations WHERE source_station='_IRL-OLD-T_SBE37' AND public_parameter='temperature_water');
  v_child := (SELECT rejection_id FROM rejected_observations WHERE parent_rejection_id=v_parent AND public_parameter='salinity');
  BEGIN PERFORM reinstate_sbe37_public_parameter(v_child,'reviewer','blocked child'); v_allowed:=true;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN v_allowed:=false; END;
  IF v_allowed THEN RAISE EXCEPTION 'dependent SBE37 child reinstatement was allowed after upgrade'; END IF;
  PERFORM reinstate_sbe37_public_parameter(v_parent,'reviewer','parent reinstatement');
  IF EXISTS (SELECT 1 FROM rejected_observations WHERE (rejection_id=v_parent OR parent_rejection_id=v_parent) AND active) THEN
    RAISE EXCEPTION 'parent reinstatement did not deactivate tree';
  END IF;
END $$;

DO $$
DECLARE v_allowed boolean:=false;
BEGIN
  BEGIN PERFORM reject_sbe37_public_parameter('_IRL-OLD-BAD_SBE37','OLD-BAD','2026-06-01 04:00+00','temprature_water',1,'bad','tester'); v_allowed:=true;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
  IF v_allowed THEN RAISE EXCEPTION 'unsupported SBE37 API parameter accepted after upgrade'; END IF;
  INSERT INTO rejected_observations (source_table,source_row_id,public_table,source_station,public_station,instrument_type,instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
  VALUES ('seabird_sbe37',(SELECT row_id FROM seabird_sbe37 WHERE station='_IRL-OLD-BAD_SBE37'),'seabird_sbeeco','_IRL-OLD-BAD_SBE37','IRL-OLD-BAD-WQ','SBE37','OLD-BAD','2026-06-01 04:00+00','bad_parameter',1,'malformed','tester');
  BEGIN UPDATE seabird_sbeeco SET conductivity=9 WHERE station='IRL-OLD-BAD-WQ'; v_allowed:=true;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN v_allowed:=false; END;
  IF v_allowed THEN RAISE EXCEPTION 'malformed SBE37 public write did not fail closed'; END IF;
  BEGIN UPDATE seabird_sbe37 SET raw_conductivity_hz=9 WHERE station='_IRL-OLD-BAD_SBE37'; v_allowed:=true;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN v_allowed:=false; END;
  IF v_allowed THEN RAISE EXCEPTION 'malformed SBE37 private replay did not fail closed'; END IF;
END $$;
