\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA sbe37_suppression_test;
SET LOCAL search_path TO sbe37_suppression_test;
CREATE TABLE seabird_sbeeco (
  station varchar NOT NULL, m_date timestamptz NOT NULL, instrument varchar,
  conductivity double precision, qc_conductivity integer, salinity double precision, qc_salinity integer,
  temperature_water double precision, qc_temperature_water integer, pressure_water double precision, qc_pressure_water integer,
  depth_instrument double precision, qc_depth_instrument integer, oxygen_saturation_perc double precision, qc_oxygen_saturation_perc integer,
  dissolved_oxygen double precision, qc_dissolved_oxygen integer, specific_conductance double precision, qc_specific_conductance integer,
  UNIQUE (station, m_date));
CREATE TABLE seabird_sbe37 (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_sbe37 varchar, raw_conductivity_hz double precision, row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, UNIQUE(station,m_date));
CREATE TABLE seabird_seafetv1 (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_seafet varchar,
  ph_tempsal double precision, qc_ph_tempsal integer, ph_int double precision, row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, UNIQUE(station,m_date));
CREATE TABLE seabird_sunav2 (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_suna varchar,
  nitrate_um double precision, qc_nitrate_um integer, nitrate_mgl double precision, qc_nitrate_mgl integer, row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, UNIQUE(station,m_date));
CREATE TABLE nortek_aquadopp (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_aquadopp varchar,
  current_speed double precision, qc_current_speed integer, current_direction double precision, qc_current_direction integer, row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, UNIQUE(station,m_date));
\ir ../sql/rejected_observations_schema.sql
\ir ../sql/seafetv1/public_parameter_suppression.sql
\ir ../sql/sbe37_public_parameter_suppression.sql
\ir ../sql/sunav2/public_parameter_suppression.sql
\ir ../sql/aquadopp/public_parameter_suppression.sql

-- Detect unnecessary public updates caused by ordinary private/raw writes.
CREATE TABLE public_update_audit (n integer NOT NULL DEFAULT 0);
INSERT INTO public_update_audit VALUES (0);
CREATE FUNCTION count_public_updates() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN UPDATE public_update_audit SET n = n + 1; RETURN NEW; END $$;
CREATE TRIGGER count_public_updates AFTER UPDATE ON seabird_sbeeco
    FOR EACH ROW EXECUTE FUNCTION count_public_updates();

-- Normal insert/replacement.
INSERT INTO seabird_sbeeco VALUES ('IRL-SB-WQ','2026-01-01 00:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3);
INSERT INTO seabird_sbe37 VALUES ('_IRL-SB_SBE37','2026-01-01 00:00+00','25799',4000);
UPDATE seabird_sbeeco SET conductivity=4.1 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
DO $$ BEGIN
 IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 4.1 THEN RAISE EXCEPTION 'normal replacement failed'; END IF;
 IF (SELECT n FROM public_update_audit) <> 1 THEN RAISE EXCEPTION 'ordinary private write updated public row'; END IF;
END $$;

SELECT reject_sbe37_public_parameter('_IRL-SB_SBE37','25799','2026-01-01 00:00+00','conductivity',2,'test bad conductivity','tester','test');
DO $$ BEGIN
 IF sbe37_public_station('_IRL-SB_SBE37') <> 'IRL-SB-WQ' THEN RAISE EXCEPTION 'private-to-public station mapping failed'; END IF;
 IF (SELECT raw_conductivity_hz FROM seabird_sbe37) <> 4000 THEN RAISE EXCEPTION 'private raw changed'; END IF;
 IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS NOT NULL OR (SELECT qc_conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 2 THEN RAISE EXCEPTION 'rejection not applied'; END IF;
 IF (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 30 THEN RAISE EXCEPTION 'other parameter changed'; END IF;
 IF sbe37_count_active_rejections('_IRL-SB_SBE37','25799','2026-01-01 00:00+00') <> 1 THEN RAISE EXCEPTION 'suppression reporting count failed'; END IF;
END $$;

-- Active uniqueness is source-observation identity, not serial provenance.
DO $$ DECLARE v_inserted boolean := false; BEGIN
 BEGIN
   INSERT INTO rejected_observations
     (source_table,source_row_id,public_table,source_station,public_station,instrument_type,
      instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
   VALUES
     ('seabird_sbe37',(SELECT row_id FROM seabird_sbe37 WHERE station='_IRL-SB_SBE37' AND m_date='2026-01-01 00:00+00'),'seabird_sbeeco','_IRL-SB_SBE37','IRL-SB-WQ','SBE37',
      '25799','2026-01-01 00:00+00','conductivity',2,'duplicate test','tester');
   v_inserted := true;
 EXCEPTION WHEN unique_violation THEN NULL;
 END;
 IF v_inserted THEN RAISE EXCEPTION 'active source-observation rejection duplicate was accepted'; END IF;
END $$;

-- Provenance serial may be NULL without creating a second identity.
INSERT INTO rejected_observations
  (source_table,public_table,source_station,public_station,instrument_type,
   instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
VALUES
  ('hypothetical_source','hypothetical_public','IRL-HYP-SRC','IRL-HYP-PUB',
   'Hypothetical','HYP-001','2026-01-01 00:00+00','hypothetical_parameter',2,
   'generic serial identity test','tester');
DO $$ DECLARE v_inserted boolean := false; BEGIN
 BEGIN
   INSERT INTO rejected_observations
     (source_table,public_table,source_station,public_station,instrument_type,
      instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
   VALUES
     ('hypothetical_source','hypothetical_public','IRL-HYP-SRC','IRL-HYP-PUB',
      'Hypothetical','HYP-001','2026-01-01 00:00+00','hypothetical_parameter',2,
      'duplicate generic serial identity test','tester');
   v_inserted := true;
 EXCEPTION WHEN unique_violation THEN NULL;
 END;
 IF v_inserted THEN RAISE EXCEPTION 'active serial rejection duplicate was accepted'; END IF;
END $$;
UPDATE rejected_observations
   SET active=false, reinstated_at=now(), reinstated_by='reviewer', reinstatement_reason='uniqueness test'
 WHERE source_table='hypothetical_source' AND active;
INSERT INTO rejected_observations
  (source_table,public_table,source_station,public_station,instrument_type,
   instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
VALUES
  ('hypothetical_source','hypothetical_public','IRL-HYP-SRC','IRL-HYP-PUB',
   'Hypothetical','HYP-001','2026-01-01 00:00+00','hypothetical_parameter',1,
   'later active generic serial identity test','tester');
DO $$ BEGIN
 IF (SELECT count(*) FROM rejected_observations WHERE source_table='hypothetical_source' AND active) <> 1 THEN
   RAISE EXCEPTION 'inactive serial rejection blocked later active rejection';
 END IF;
END $$;

INSERT INTO rejected_observations
  (source_table,public_table,source_station,public_station,instrument_type,instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
VALUES ('missing_serial_fixture','fixture_public','IRL-MISS-SRC','IRL-MISS-PUB','Fixture',NULL,'2026-01-01 00:00+00','fixture_parameter',2,'missing serial provenance test','tester');

-- qc_flag is the established IRLON QARTOD rollup, not a rejection category:
-- 1 = bad, 2 = suspect, 3 = good. All three values are accepted.
INSERT INTO rejected_observations
  (source_table,public_table,source_station,public_station,instrument_type,
   instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
VALUES
  ('qartod_fixture','qartod_public','IRL-QC-SRC','IRL-QC-PUB','QARTOD fixture',
   'QARTOD-001','2026-01-01 00:00+00','flag_bad',1,'QARTOD bad test','tester'),
  ('qartod_fixture','qartod_public','IRL-QC-SRC','IRL-QC-PUB','QARTOD fixture',
   'QARTOD-001','2026-01-01 00:00+00','flag_suspect',2,'QARTOD suspect test','tester'),
  ('qartod_fixture','qartod_public','IRL-QC-SRC','IRL-QC-PUB','QARTOD fixture',
   'QARTOD-001','2026-01-01 00:00+00','flag_good',3,'QARTOD good test','tester');
DO $$ BEGIN
 IF (SELECT count(*) FROM rejected_observations WHERE source_table='qartod_fixture' AND qc_flag IN (1,2,3)) <> 3 THEN
   RAISE EXCEPTION 'valid QARTOD rollup values were not all accepted';
 END IF;
END $$;

-- Values outside the established vocabulary, and NULL, are rejected by the
-- registry constraints.
DO $$ DECLARE v_inserted boolean := false; BEGIN
 BEGIN
   INSERT INTO rejected_observations
     (source_table,public_table,source_station,public_station,instrument_type,instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
   VALUES ('qartod_invalid','qartod_public','IRL-QC-SRC','IRL-QC-PUB','QARTOD fixture','QARTOD-INVALID','2026-01-01 00:00+00','flag_zero',0,'invalid QARTOD test','tester');
   v_inserted := true;
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 IF v_inserted THEN RAISE EXCEPTION 'qc_flag 0 was accepted'; END IF;
END $$;
DO $$ DECLARE v_inserted boolean := false; BEGIN
 BEGIN
   INSERT INTO rejected_observations
     (source_table,public_table,source_station,public_station,instrument_type,instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
   VALUES ('qartod_invalid','qartod_public','IRL-QC-SRC','IRL-QC-PUB','QARTOD fixture','QARTOD-INVALID','2026-01-01 00:00+00','flag_four',4,'invalid QARTOD test','tester');
   v_inserted := true;
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 IF v_inserted THEN RAISE EXCEPTION 'qc_flag 4 was accepted'; END IF;
END $$;
DO $$ DECLARE v_inserted boolean := false; BEGIN
 BEGIN
   INSERT INTO rejected_observations
     (source_table,public_table,source_station,public_station,instrument_type,instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
   VALUES ('qartod_invalid','qartod_public','IRL-QC-SRC','IRL-QC-PUB','QARTOD fixture','QARTOD-INVALID','2026-01-01 00:00+00','flag_null',NULL,'invalid QARTOD test','tester');
   v_inserted := true;
 EXCEPTION WHEN not_null_violation THEN NULL;
 END;
 IF v_inserted THEN RAISE EXCEPTION 'qc_flag NULL was accepted'; END IF;
END $$;

-- The guard derives the unique mapped private source row; no serial context is needed.
RESET irlon.sbe37_source_station;
RESET irlon.sbe37_serial_number;
DO $$ DECLARE v_allowed boolean := false; BEGIN
 BEGIN
   UPDATE seabird_sbeeco SET conductivity=99 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF NOT v_allowed OR (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS NOT NULL THEN RAISE EXCEPTION 'context-free source identity failed'; END IF;
END $$;

-- Serial context is ignored; the mapped source station/timestamp is authoritative.
DO $$ DECLARE v_allowed boolean; BEGIN
 v_allowed := false;
 BEGIN
   PERFORM sbe37_set_public_write_identity('_IRL-OTHER_SBE37','25799');
   UPDATE seabird_sbeeco SET conductivity=99 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF NOT v_allowed THEN RAISE EXCEPTION 'unrelated serial context changed source identity'; END IF;
 v_allowed := false;
 BEGIN
   PERFORM sbe37_set_public_write_identity('_IRL-SB_SBE37','fabricated');
   UPDATE seabird_sbeeco SET conductivity=99 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF NOT v_allowed THEN RAISE EXCEPTION 'fabricated serial context changed source identity'; END IF;
END $$;
SAVEPOINT missing_private_timestamp;
UPDATE seabird_sbe37 SET m_date='2026-01-01 01:00+00';
DO $$ DECLARE v_allowed boolean := false; BEGIN
 BEGIN
   PERFORM sbe37_set_public_write_identity('_IRL-SB_SBE37','25799');
   UPDATE seabird_sbeeco SET conductivity=99 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed THEN RAISE EXCEPTION 'missing private timestamp unexpectedly allowed'; END IF;
END $$;
ROLLBACK TO missing_private_timestamp;

-- Commit the fixture so the following CTE is a true autocommit statement,
-- matching the current R writers' DBI behavior. The disposable container is
-- discarded after the test.
COMMIT;
SET search_path TO sbe37_suppression_test;

-- Representative writer form: identity and public upsert are one autocommit statement.
WITH identity AS MATERIALIZED (
  SELECT sbe37_set_public_write_identity('_IRL-SB_SBE37', '25799')
), candidate AS MATERIALIZED (
  SELECT 'IRL-SB-WQ'::varchar AS station, '2026-01-01 00:00+00'::timestamptz AS m_date,
         'SBE37/ECO'::varchar AS instrument, 7::double precision AS conductivity, 31::double precision AS salinity
)
INSERT INTO seabird_sbeeco (station, m_date, instrument, conductivity, salinity)
SELECT c.station, c.m_date, c.instrument, c.conductivity, c.salinity FROM candidate c CROSS JOIN identity
ON CONFLICT (station, m_date) DO UPDATE SET instrument=EXCLUDED.instrument, conductivity=EXCLUDED.conductivity, salinity=EXCLUDED.salinity;
DO $$ BEGIN IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS NOT NULL OR (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 31 THEN RAISE EXCEPTION 'replay suppression failed'; END IF; END $$;
DO $$ BEGIN
 IF NULLIF(current_setting('irlon.sbe37_source_station', true), '') IS NOT NULL THEN RAISE EXCEPTION 'statement-local identity leaked'; END IF;
END $$;
DO $$ DECLARE v_allowed boolean := false; BEGIN
 BEGIN
   UPDATE seabird_sbeeco SET conductivity=66 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF NOT v_allowed OR (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS NOT NULL THEN
   RAISE EXCEPTION 'later public replay was not source-observation suppressed';
 END IF;
END $$;

-- The same single-statement form works normally when no rejection applies.
INSERT INTO seabird_sbeeco (station,m_date,instrument,conductivity) VALUES ('IRL-NO-WQ','2026-01-01 00:00+00','SBE37/ECO',1);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz) VALUES ('_IRL-NO_SBE37','2026-01-01 00:00+00','11111',1000);
WITH identity AS MATERIALIZED (
  SELECT sbe37_set_public_write_identity('_IRL-NO_SBE37', '11111')
), candidate AS MATERIALIZED (
  SELECT 'IRL-NO-WQ'::varchar AS station, '2026-01-01 00:00+00'::timestamptz AS m_date,
         'SBE37/ECO'::varchar AS instrument, 2::double precision AS conductivity
)
INSERT INTO seabird_sbeeco (station, m_date, instrument, conductivity)
SELECT c.station, c.m_date, c.instrument, c.conductivity FROM candidate c CROSS JOIN identity
ON CONFLICT (station, m_date) DO UPDATE SET instrument=EXCLUDED.instrument, conductivity=EXCLUDED.conductivity;
DO $$ BEGIN IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-NO-WQ') <> 2 THEN RAISE EXCEPTION 'normal single-statement upsert failed'; END IF; END $$;

BEGIN;
SET LOCAL search_path TO sbe37_suppression_test;

-- PostgreSQL's real unique (station,m_date) private key means the different
-- serial is represented by its real private upsert before public publication.
UPDATE seabird_sbe37 SET serial_number_sbe37='99999', raw_conductivity_hz=8000 WHERE station='_IRL-SB_SBE37' AND m_date='2026-01-01 00:00+00';
WITH identity AS MATERIALIZED (
  SELECT sbe37_set_public_write_identity('_IRL-SB_SBE37', '99999')
), candidate AS MATERIALIZED (
  SELECT 'IRL-SB-WQ'::varchar AS station, '2026-01-01 00:00+00'::timestamptz AS m_date,
         'SBE37/ECO'::varchar AS instrument, 8::double precision AS conductivity
)
INSERT INTO seabird_sbeeco (station, m_date, instrument, conductivity)
SELECT c.station, c.m_date, c.instrument, c.conductivity FROM candidate c CROSS JOIN identity
ON CONFLICT (station, m_date) DO UPDATE SET instrument=EXCLUDED.instrument, conductivity=EXCLUDED.conductivity;
DO $$ BEGIN IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS NOT NULL THEN RAISE EXCEPTION 'serial correction created a second identity'; END IF; END $$;

-- A legacy/private-only upsert cannot repopulate public data; its AFTER trigger re-nulls it.
UPDATE seabird_sbe37 SET raw_conductivity_hz=7100, serial_number_sbe37='25799' WHERE station='_IRL-SB_SBE37' AND m_date='2026-01-01 00:00+00';
DO $$ BEGIN IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS NOT NULL THEN RAISE EXCEPTION 'private replay bypassed suppression'; END IF; END $$;

-- A failing single statement rolls back its candidate update completely.
DO $$ DECLARE v_before double precision; v_allowed boolean := false; BEGIN
 v_before := (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SB-WQ');
 BEGIN
   WITH identity AS MATERIALIZED (
     SELECT sbe37_set_public_write_identity('_IRL-OTHER_SBE37', '25799')
   ), candidate AS MATERIALIZED (
     SELECT 'IRL-SB-WQ'::varchar AS station, '2026-01-01 00:00+00'::timestamptz AS m_date,
            'SBE37/ECO'::varchar AS instrument, 99::double precision AS salinity
   )
   INSERT INTO seabird_sbeeco (station, m_date, instrument, salinity)
   SELECT c.station, c.m_date, c.instrument, c.salinity FROM candidate c CROSS JOIN identity
   ON CONFLICT (station, m_date) DO UPDATE SET instrument=EXCLUDED.instrument, salinity=EXCLUDED.salinity;
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF NOT v_allowed THEN RAISE EXCEPTION 'serial context unexpectedly blocked source-observation write'; END IF;
 IF (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 99 THEN RAISE EXCEPTION 'unrelated parameter changed unexpectedly'; END IF;
END $$;

-- Reinstatement is audited and permits a future write; it does not reconstruct history.
SELECT reinstate_sbe37_public_parameter((SELECT rejection_id FROM rejected_observations WHERE source_table='seabird_sbe37'),'reviewer','validated correction');
SELECT sbe37_set_public_write_identity('_IRL-SB_SBE37','25799');
UPDATE seabird_sbeeco SET conductivity=6 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
DO $$ BEGIN
 IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 6
    OR (SELECT active FROM rejected_observations WHERE source_table='seabird_sbe37')
    OR EXISTS (SELECT 1 FROM rejected_observations WHERE source_table='seabird_sbe37'
                 AND (reinstated_at IS NULL OR reinstated_by IS NULL OR reinstatement_reason IS NULL)) THEN
   RAISE EXCEPTION 'standalone SBE37 reinstatement failed';
 END IF;
END $$;

-- The rejection API is atomic under rollback.
SAVEPOINT rejection_rollback;
SELECT reject_sbe37_public_parameter('_IRL-SB_SBE37','25799','2026-01-01 00:00+00','salinity',1,'rollback','tester');
ROLLBACK TO rejection_rollback;
DO $$ BEGIN IF (SELECT count(*) FROM rejected_observations WHERE source_table='seabird_sbe37') <> 1 OR (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 99 THEN RAISE EXCEPTION 'rollback was partial'; END IF; END $$;

-- Additional modules: source-specific fixed parameter handling, raw preservation,
-- replay, serial mismatch rejection, and audited reinstatement.
INSERT INTO seabird_seafetv1 VALUES ('_IRL-SF_SEAFETV1','2026-02-01 00:00+00','SF-1',NULL,NULL,7.9),('IRL-SF-WQ','2026-02-01 00:00+00',NULL,8.1,3,NULL);
SELECT reject_seafetv1_public_parameter('_IRL-SF_SEAFETV1','SF-1','2026-02-01 00:00+00','ph_tempsal',1,'test','tester');
DO $$ BEGIN
 IF (SELECT ph_int FROM seabird_seafetv1 WHERE station='_IRL-SF_SEAFETV1') <> 7.9 THEN RAISE EXCEPTION 'SeaFET raw value changed'; END IF;
 IF (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SF-WQ') IS NOT NULL OR (SELECT qc_ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SF-WQ')<>1 THEN RAISE EXCEPTION 'SeaFET rejection failed'; END IF;
END $$;
DO $$ DECLARE ok boolean:=false; BEGIN BEGIN PERFORM reject_seafetv1_public_parameter('_IRL-SF_SEAFETV1','SF-1','2026-02-01 00:00+00','ph_ext',1,'test','tester'); ok:=true; EXCEPTION WHEN others THEN NULL; END; IF ok THEN RAISE EXCEPTION 'SeaFET unsupported parameter accepted'; END IF; END $$;
UPDATE seabird_seafetv1 SET ph_tempsal=8.2,qc_ph_tempsal=3 WHERE station='IRL-SF-WQ' AND m_date='2026-02-01 00:00+00';
DO $$ BEGIN IF (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SF-WQ') IS NOT NULL THEN RAISE EXCEPTION 'SeaFET guard bypassed'; END IF; END $$;
SELECT reinstate_seafetv1_public_parameter('_IRL-SF_SEAFETV1','SF-1','2026-02-01 00:00+00','ph_tempsal','reviewer','standalone reinstatement');
UPDATE seabird_seafetv1 SET ph_tempsal=8.2,qc_ph_tempsal=3 WHERE station='IRL-SF-WQ' AND m_date='2026-02-01 00:00+00';
DO $$ BEGIN
 IF (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SF-WQ') <> 8.2
    OR EXISTS (SELECT 1 FROM rejected_observations WHERE source_table='seabird_seafetv1' AND source_station='_IRL-SF_SEAFETV1' AND active)
    OR EXISTS (SELECT 1 FROM rejected_observations WHERE source_table='seabird_seafetv1' AND source_station='_IRL-SF_SEAFETV1'
                 AND (reinstated_at IS NULL OR reinstated_by IS NULL OR reinstatement_reason IS NULL)) THEN
   RAISE EXCEPTION 'standalone SeaFET reinstatement failed';
 END IF;
END $$;

-- Direct/manual SeaFET registry insertion must fail closed on both public
-- replay and private reapply; only ph_tempsal is supported by this module.
INSERT INTO seabird_seafetv1 VALUES ('_IRL-DEF-SF_SEAFETV1','2026-02-01 01:00+00','DEF-SF',NULL,NULL,7.8),('IRL-DEF-SF-WQ','2026-02-01 01:00+00',NULL,8.0,3,NULL);
INSERT INTO rejected_observations
  (source_table,source_row_id,public_table,source_station,public_station,instrument_type,
   instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
VALUES ('seabird_seafetv1',(SELECT row_id FROM seabird_seafetv1 WHERE station='_IRL-DEF-SF_SEAFETV1' AND m_date='2026-02-01 01:00+00'),
        'seabird_seafetv1','_IRL-DEF-SF_SEAFETV1','IRL-DEF-SF-WQ','SeaFET v1','DEF-SF',
        '2026-02-01 01:00+00','ph_tempsall',1,'defensive guard test','tester');
DO $$ DECLARE v_allowed boolean := false; BEGIN
 BEGIN
   UPDATE seabird_seafetv1 SET ph_tempsal=8.1 WHERE station='IRL-DEF-SF-WQ' AND m_date='2026-02-01 01:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed OR (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-DEF-SF-WQ' AND m_date='2026-02-01 01:00+00') <> 8.0 THEN
   RAISE EXCEPTION 'SeaFET public guard did not fail closed for direct invalid registry row';
 END IF;
 v_allowed := false;
 BEGIN
   UPDATE seabird_seafetv1 SET ph_int=7.7 WHERE station='_IRL-DEF-SF_SEAFETV1' AND m_date='2026-02-01 01:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed OR (SELECT ph_int FROM seabird_seafetv1 WHERE station='_IRL-DEF-SF_SEAFETV1' AND m_date='2026-02-01 01:00+00') <> 7.8 THEN
   RAISE EXCEPTION 'SeaFET private reapply did not fail closed for direct invalid registry row';
 END IF;
END $$;

INSERT INTO seabird_sunav2 VALUES ('_IRL-SF_SUNA','2026-02-01 00:00+00','SU-1',NULL,NULL,NULL,NULL),('IRL-SF-WQ','2026-02-01 00:00+00',NULL,10,3,2,3);
SELECT reject_sunav2_public_parameter('_IRL-SF_SUNA','SU-1','2026-02-01 00:00+00','nitrate_um',2,'test','tester');
UPDATE seabird_sunav2 SET nitrate_um=11,qc_nitrate_um=3,nitrate_mgl=2.1 WHERE station='IRL-SF-WQ' AND m_date='2026-02-01 00:00+00';
DO $$ BEGIN IF (SELECT nitrate_um FROM seabird_sunav2 WHERE station='IRL-SF-WQ') IS NOT NULL OR (SELECT qc_nitrate_um FROM seabird_sunav2 WHERE station='IRL-SF-WQ')<>2 OR (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-SF-WQ')<>2.1 THEN RAISE EXCEPTION 'SUNA fixed-parameter guard failed'; END IF; END $$;
SELECT reject_sunav2_public_parameter('_IRL-SF_SUNA','fabricated','2026-02-01 00:00+00','nitrate_mgl',3,'test','tester');
DO $$ BEGIN IF (SELECT instrument_serial FROM rejected_observations WHERE source_table='seabird_sunav2' AND public_parameter='nitrate_mgl') <> 'SU-1' THEN RAISE EXCEPTION 'SUNA serial provenance was not taken from source row'; END IF; END $$;
DO $$ DECLARE ok boolean:=false; BEGIN BEGIN PERFORM reject_sunav2_public_parameter('_IRL-SF_SUNA','SU-1','2026-02-01 00:00+00','fit_rmse',1,'test','tester'); ok:=true; EXCEPTION WHEN others THEN NULL; END; IF ok THEN RAISE EXCEPTION 'SUNA unsupported parameter accepted'; END IF; END $$;

-- SUNA's real writer uses separate autocommit statements: private first, then
-- public.  The guard derives identity from the committed private row; no GUC or
-- other session context is set, so there is nothing to leak into later writes.
INSERT INTO seabird_sunav2 VALUES ('_IRL-AUTO_SUNA','2026-02-02 00:00+00','SU-AUTO',NULL,NULL,NULL,NULL);
SELECT reject_sunav2_public_parameter('_IRL-AUTO_SUNA','SU-AUTO','2026-02-02 00:00+00','nitrate_mgl',1,'autocommit writer proof','tester');
COMMIT;
BEGIN;
SET LOCAL search_path TO sbe37_suppression_test;
INSERT INTO seabird_sunav2 VALUES ('IRL-AUTO-WQ','2026-02-02 00:00+00',NULL,12,3,2.4,3);
DO $$ BEGIN
 IF (SELECT nitrate_um FROM seabird_sunav2 WHERE station='IRL-AUTO-WQ') <> 12
    OR (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-AUTO-WQ') IS NOT NULL
    OR (SELECT qc_nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-AUTO-WQ') <> 1
 THEN RAISE EXCEPTION 'SUNA private-first autocommit guard proof failed'; END IF;
 IF sunav2_count_active_rejections('_IRL-AUTO_SUNA','SU-AUTO','2026-02-02 00:00+00') <> 1
 THEN RAISE EXCEPTION 'SUNA suppression reporting count failed'; END IF;
END $$;
-- An unrelated public write remains normal: there is no session identity state.
INSERT INTO seabird_sunav2 VALUES ('IRL-OTHER-WQ','2026-02-02 00:00+00',NULL,13,3,2.5,3);
DO $$ BEGIN IF (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-OTHER-WQ') <> 2.5 THEN RAISE EXCEPTION 'SUNA identity leaked to unrelated public write'; END IF; END $$;
SAVEPOINT sunav2_writer_atomicity;
INSERT INTO seabird_sunav2 VALUES ('_IRL-ROLL_SUNA','2026-02-03 00:00+00','SU-ROLL',NULL,NULL,NULL,NULL);
ROLLBACK TO sunav2_writer_atomicity;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM seabird_sunav2 WHERE station='_IRL-ROLL_SUNA') THEN RAISE EXCEPTION 'SUNA writer transaction rollback was partial'; END IF; END $$;

INSERT INTO nortek_aquadopp VALUES ('_IRL-SF_AQUADOPP','2026-02-01 00:00+00','AQ-1',NULL,NULL,NULL,NULL),('IRL-SF-WQ','2026-02-01 00:00+00',NULL,1,3,90,3);
SELECT reject_aquadopp_public_parameter('_IRL-SF_AQUADOPP','AQ-1','2026-02-01 00:00+00','current_speed',3,'test','tester');
UPDATE nortek_aquadopp SET current_speed=2,qc_current_speed=1,current_direction=91 WHERE station='IRL-SF-WQ' AND m_date='2026-02-01 00:00+00';
DO $$ BEGIN IF (SELECT current_speed FROM nortek_aquadopp WHERE station='IRL-SF-WQ') IS NOT NULL OR (SELECT qc_current_speed FROM nortek_aquadopp WHERE station='IRL-SF-WQ')<>3 OR (SELECT current_direction FROM nortek_aquadopp WHERE station='IRL-SF-WQ')<>91 THEN RAISE EXCEPTION 'Aquadopp fixed-parameter guard failed'; END IF; END $$;
SELECT reinstate_aquadopp_public_parameter('_IRL-SF_AQUADOPP','AQ-1','2026-02-01 00:00+00','current_speed','reviewer');
UPDATE nortek_aquadopp SET current_speed=2 WHERE station='IRL-SF-WQ' AND m_date='2026-02-01 00:00+00';
DO $$ BEGIN IF (SELECT current_speed FROM nortek_aquadopp WHERE station='IRL-SF-WQ')<>2 THEN RAISE EXCEPTION 'Aquadopp reinstatement failed'; END IF; END $$;
DO $$ DECLARE ok boolean:=false; BEGIN BEGIN PERFORM reject_aquadopp_public_parameter('_IRL-SF_AQUADOPP','AQ-1','2026-02-01 00:00+00','current_east',1,'test','tester'); ok:=true; EXCEPTION WHEN others THEN NULL; END; IF ok THEN RAISE EXCEPTION 'Aquadopp unsupported parameter accepted'; END IF; END $$;

-- SeaFET's bounded, two-sided recovery accepts an otherwise blank source serial
-- only when both adjacent source observations agree.
INSERT INTO seabird_seafetv1 VALUES ('_IRL-GAP_SEAFETV1','2026-02-01 00:00+00','GAP-1',NULL,NULL,7),('_IRL-GAP_SEAFETV1','2026-02-01 01:00+00',NULL,NULL,NULL,7),('_IRL-GAP_SEAFETV1','2026-02-01 02:00+00','GAP-1',NULL,NULL,7),('IRL-GAP-WQ','2026-02-01 01:00+00',NULL,8,3,NULL);
DO $$ BEGIN IF seafetv1_resolve_serial('_IRL-GAP_SEAFETV1','2026-02-01 01:00+00') <> 'GAP-1' THEN RAISE EXCEPTION 'SeaFET bounded serial recovery failed'; END IF; END $$;

-- Derived-parameter governance: SBE37 water temperature is the parent input
-- to SBE37 salinity/dissolved oxygen and, where a matching private SeaFET row
-- exists, to SeaFET pH.  All children use the parent's QARTOD rollup and have
-- their own immutable source-table/row_id provenance.
INSERT INTO seabird_sbeeco VALUES ('IRL-DER-WQ','2026-03-01 00:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz)
  VALUES ('_IRL-DER_SBE37','2026-03-01 00:00+00',NULL,4000);
INSERT INTO seabird_seafetv1 (station,m_date,serial_number_seafet,ph_tempsal,qc_ph_tempsal,ph_int)
  VALUES ('_IRL-DER_SEAFETV1','2026-03-01 00:00+00',NULL,NULL,NULL,7.9),
         ('IRL-DER-WQ','2026-03-01 00:00+00',NULL,8.1,3,NULL);
SELECT reject_sbe37_public_parameter('_IRL-DER_SBE37',NULL,'2026-03-01 00:00+00','temperature_water',1,'bad source temperature','tester','derived test');
DO $$
DECLARE v_parent bigint := (SELECT rejection_id FROM rejected_observations
  WHERE source_table='seabird_sbe37' AND source_station='_IRL-DER_SBE37'
    AND m_date='2026-03-01 00:00+00' AND public_parameter='temperature_water' AND active);
        v_salinity_child bigint;
BEGIN
 v_salinity_child := (SELECT rejection_id FROM rejected_observations WHERE parent_rejection_id=v_parent AND public_parameter='salinity' AND active);
 IF (SELECT temperature_water FROM seabird_sbeeco WHERE station='IRL-DER-WQ') IS NOT NULL
    OR (SELECT qc_temperature_water FROM seabird_sbeeco WHERE station='IRL-DER-WQ') <> 1
    OR (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-DER-WQ') IS NOT NULL
    OR (SELECT qc_salinity FROM seabird_sbeeco WHERE station='IRL-DER-WQ') <> 1
    OR (SELECT dissolved_oxygen FROM seabird_sbeeco WHERE station='IRL-DER-WQ') IS NOT NULL
    OR (SELECT qc_dissolved_oxygen FROM seabird_sbeeco WHERE station='IRL-DER-WQ') <> 1
    OR (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-DER-WQ') IS NOT NULL
    OR (SELECT qc_ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-DER-WQ') <> 1 THEN
   RAISE EXCEPTION 'temperature dependency suppression/QARTOD propagation failed';
 END IF;
 -- Direct children of the temperature parent are exactly salinity and
 -- dissolved oxygen; pH is a grandchild reached transitively through salinity
 -- (temperature_water -> salinity -> ph_tempsal), giving it a single provenance path.
 IF (SELECT count(*) FROM rejected_observations WHERE parent_rejection_id=v_parent AND active) <> 2 THEN
   RAISE EXCEPTION 'expected exactly SBE37 salinity and dissolved oxygen as direct temperature children';
 END IF;
 IF v_salinity_child IS NULL THEN RAISE EXCEPTION 'temperature rejection did not create a salinity child'; END IF;
 IF (SELECT count(*) FROM rejected_observations WHERE parent_rejection_id=v_salinity_child AND active) <> 1
    OR NOT EXISTS (SELECT 1 FROM rejected_observations WHERE parent_rejection_id=v_salinity_child AND public_parameter='ph_tempsal' AND active) THEN
   RAISE EXCEPTION 'salinity child did not create the transitive SeaFET pH grandchild';
 END IF;
 IF EXISTS (
   SELECT 1 FROM rejected_observations r LEFT JOIN seabird_sbe37 s
     ON r.source_table='seabird_sbe37' AND r.source_row_id=s.row_id
    WHERE r.rejection_id=v_parent AND (r.source_row_id IS NULL OR s.row_id IS NULL)
 ) THEN RAISE EXCEPTION 'SBE37 parent did not record its immutable source row'; END IF;
 IF EXISTS (
   SELECT 1 FROM rejected_observations r LEFT JOIN seabird_seafetv1 sf
     ON r.source_table='seabird_seafetv1' AND r.source_row_id=sf.row_id
    WHERE r.parent_rejection_id=v_salinity_child AND r.source_table='seabird_seafetv1'
      AND (r.source_row_id IS NULL OR sf.row_id IS NULL)
 ) THEN RAISE EXCEPTION 'SeaFET grandchild did not record its immutable source row'; END IF;
END $$;
DO $$
DECLARE v_parent bigint := (SELECT rejection_id FROM rejected_observations
  WHERE source_table='seabird_sbe37' AND source_station='_IRL-DER_SBE37'
    AND m_date='2026-03-01 00:00+00' AND public_parameter='temperature_water' AND active);
        v_salinity_child bigint := (SELECT rejection_id FROM rejected_observations WHERE parent_rejection_id=(SELECT rejection_id FROM rejected_observations
          WHERE source_table='seabird_sbe37' AND source_station='_IRL-DER_SBE37'
            AND m_date='2026-03-01 00:00+00' AND public_parameter='temperature_water' AND active)
          AND public_parameter='salinity' AND active);
        v_child bigint; v_allowed boolean;
BEGIN
 FOREACH v_child IN ARRAY ARRAY[
   (SELECT rejection_id FROM rejected_observations WHERE parent_rejection_id=v_parent AND public_parameter='salinity' AND active),
   (SELECT rejection_id FROM rejected_observations WHERE parent_rejection_id=v_parent AND public_parameter='dissolved_oxygen' AND active)
 ] LOOP
   v_allowed := false;
   BEGIN
     PERFORM reinstate_sbe37_public_parameter(v_child,'reviewer','direct child attempt');
     v_allowed := true;
   EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
   END;
   IF v_allowed OR NOT (SELECT active FROM rejected_observations WHERE rejection_id=v_parent)
      OR NOT (SELECT active FROM rejected_observations WHERE rejection_id=v_child) THEN
     RAISE EXCEPTION 'SBE37 dependent child reinstatement was not blocked';
   END IF;
 END LOOP;
 v_allowed := false;
 BEGIN
   PERFORM reinstate_seafetv1_public_parameter('_IRL-DER_SEAFETV1',NULL,'2026-03-01 00:00+00','ph_tempsal','reviewer','direct grandchild attempt');
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed OR NOT (SELECT active FROM rejected_observations WHERE rejection_id=v_parent)
    OR NOT (SELECT active FROM rejected_observations WHERE rejection_id=v_salinity_child)
    OR NOT EXISTS (SELECT 1 FROM rejected_observations WHERE parent_rejection_id=v_salinity_child AND public_parameter='ph_tempsal' AND active) THEN
   RAISE EXCEPTION 'SeaFET dependent grandchild reinstatement was not blocked';
 END IF;
END $$;
SELECT reinstate_sbe37_public_parameter(
  (SELECT rejection_id FROM rejected_observations WHERE source_table='seabird_sbe37'
    AND source_station='_IRL-DER_SBE37' AND m_date='2026-03-01 00:00+00'
    AND public_parameter='temperature_water' AND active), 'reviewer','parent reinstated');
DO $$
DECLARE v_parent bigint := (SELECT rejection_id FROM rejected_observations
  WHERE source_table='seabird_sbe37' AND source_station='_IRL-DER_SBE37'
    AND m_date='2026-03-01 00:00+00' AND public_parameter='temperature_water');
BEGIN
 -- The full three-level subtree (temperature -> salinity -> pH, and
 -- temperature -> dissolved oxygen) must be released together.
 IF EXISTS (
   WITH RECURSIVE descendants AS (
     SELECT rejection_id FROM rejected_observations WHERE rejection_id = v_parent
     UNION ALL
     SELECT r.rejection_id FROM rejected_observations r JOIN descendants d ON r.parent_rejection_id = d.rejection_id
   )
   SELECT 1 FROM rejected_observations WHERE rejection_id IN (SELECT rejection_id FROM descendants) AND active
 ) THEN
   RAISE EXCEPTION 'parent reinstatement did not deactivate its full derived subtree';
 END IF;
 IF EXISTS (
   WITH RECURSIVE descendants AS (
     SELECT rejection_id FROM rejected_observations WHERE rejection_id = v_parent
     UNION ALL
     SELECT r.rejection_id FROM rejected_observations r JOIN descendants d ON r.parent_rejection_id = d.rejection_id
   )
   SELECT 1 FROM rejected_observations WHERE rejection_id IN (SELECT rejection_id FROM descendants)
     AND (reinstated_at IS NULL OR reinstated_by IS NULL OR reinstatement_reason IS NULL)
 ) THEN
   RAISE EXCEPTION 'parent reinstatement did not audit its full derived subtree consistently';
 END IF;
 UPDATE seabird_sbeeco SET temperature_water=21,salinity=31,dissolved_oxygen=9 WHERE station='IRL-DER-WQ';
 UPDATE seabird_seafetv1 SET ph_tempsal=8.2,qc_ph_tempsal=3 WHERE station='IRL-DER-WQ';
 IF (SELECT temperature_water FROM seabird_sbeeco WHERE station='IRL-DER-WQ') <> 21
    OR (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-DER-WQ') <> 31
    OR (SELECT dissolved_oxygen FROM seabird_sbeeco WHERE station='IRL-DER-WQ') <> 9
    OR (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-DER-WQ') <> 8.2 THEN
   RAISE EXCEPTION 'reinstated parent still blocked normal replay';
 END IF;
END $$;

-- Option 1: no matching SeaFET source row must not prevent the SBE37 parent
-- and its same-row SBE37 children from being recorded and enforced.
INSERT INTO seabird_sbeeco VALUES ('IRL-NOPH-WQ','2026-03-01 01:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz)
  VALUES ('_IRL-NOPH_SBE37','2026-03-01 01:00+00',NULL,4000);
SELECT reject_sbe37_public_parameter('_IRL-NOPH_SBE37',NULL,'2026-03-01 01:00+00','temperature_water',2,'no SeaFET source','tester');
DO $$ DECLARE v_parent bigint := (SELECT rejection_id FROM rejected_observations
  WHERE source_table='seabird_sbe37' AND source_station='_IRL-NOPH_SBE37'
    AND m_date='2026-03-01 01:00+00' AND public_parameter='temperature_water' AND active); BEGIN
 IF (SELECT count(*) FROM rejected_observations WHERE parent_rejection_id=v_parent AND active) <> 2 THEN
   RAISE EXCEPTION 'missing SeaFET source should leave only the two SBE37 derived children';
 END IF;
END $$;

-- SALINITY -> PH_TEMPSAL: a standalone salinity rejection (not derived from a
-- temperature rejection) must independently create and enforce a linked
-- SeaFET pH child, per seafet_ascii/R/seafet_ascii_process_recurring_final.R
-- (salinity is a required, non-derivable input to the pH calculation).
INSERT INTO seabird_sbeeco VALUES ('IRL-SAL-WQ','2026-05-01 00:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz)
  VALUES ('_IRL-SAL_SBE37','2026-05-01 00:00+00','SAL-1',4000);
INSERT INTO seabird_seafetv1 (station,m_date,serial_number_seafet,ph_tempsal,qc_ph_tempsal,ph_int)
  VALUES ('_IRL-SAL_SEAFETV1','2026-05-01 00:00+00','SF-SAL',NULL,NULL,7.9),
         ('IRL-SAL-WQ','2026-05-01 00:00+00',NULL,8.1,3,NULL);
SELECT reject_sbe37_public_parameter('_IRL-SAL_SBE37','SAL-1','2026-05-01 00:00+00','salinity',2,'bad source salinity','tester','salinity dependency test');
DO $$
DECLARE v_salinity bigint := (SELECT rejection_id FROM rejected_observations
  WHERE source_table='seabird_sbe37' AND source_station='_IRL-SAL_SBE37'
    AND m_date='2026-05-01 00:00+00' AND public_parameter='salinity' AND active);
        v_ph bigint;
BEGIN
 IF v_salinity IS NULL THEN RAISE EXCEPTION 'standalone salinity rejection was not recorded'; END IF;
 IF (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SAL-WQ') IS NOT NULL
    OR (SELECT qc_salinity FROM seabird_sbeeco WHERE station='IRL-SAL-WQ') <> 2
    OR (SELECT temperature_water FROM seabird_sbeeco WHERE station='IRL-SAL-WQ') IS NULL THEN
   RAISE EXCEPTION 'standalone salinity rejection suppression failed or leaked to temperature';
 END IF;
 IF (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SAL-WQ') IS NOT NULL
    OR (SELECT qc_ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SAL-WQ') <> 2 THEN
   RAISE EXCEPTION 'standalone salinity rejection did not suppress matching SeaFET pH';
 END IF;
 v_ph := (SELECT rejection_id FROM rejected_observations WHERE parent_rejection_id=v_salinity AND public_parameter='ph_tempsal' AND active);
 IF v_ph IS NULL THEN RAISE EXCEPTION 'standalone salinity rejection did not create/audit a linked SeaFET pH child'; END IF;
 IF (SELECT source_table FROM rejected_observations WHERE rejection_id=v_ph) <> 'seabird_seafetv1'
    OR (SELECT source_row_id FROM rejected_observations WHERE rejection_id=v_ph) IS NULL THEN
   RAISE EXCEPTION 'SeaFET pH child from salinity did not record its immutable source row';
 END IF;
END $$;
DO $$ DECLARE v_ph bigint := (SELECT rejection_id FROM rejected_observations
  WHERE source_table='seabird_seafetv1' AND source_station='_IRL-SAL_SEAFETV1'
    AND m_date='2026-05-01 00:00+00' AND public_parameter='ph_tempsal' AND active);
  v_allowed boolean := false;
BEGIN
 -- Direct child reinstatement fails while salinity remains active.
 BEGIN
   PERFORM reinstate_seafetv1_public_parameter('_IRL-SAL_SEAFETV1','SF-SAL','2026-05-01 00:00+00','ph_tempsal','reviewer','direct child attempt');
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed OR NOT (SELECT active FROM rejected_observations WHERE rejection_id=v_ph) THEN
   RAISE EXCEPTION 'SeaFET pH child of salinity was reinstated while salinity remained active';
 END IF;
 -- Public SeaFET rewrite cannot restore pH.
 UPDATE seabird_seafetv1 SET ph_tempsal=8.4,qc_ph_tempsal=3 WHERE station='IRL-SAL-WQ' AND m_date='2026-05-01 00:00+00';
 IF (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SAL-WQ') IS NOT NULL THEN
   RAISE EXCEPTION 'public SeaFET rewrite restored pH suppressed via salinity dependency';
 END IF;
 -- Private SeaFET replay cannot restore pH.
 UPDATE seabird_seafetv1 SET ph_int=8.0 WHERE station='_IRL-SAL_SEAFETV1' AND m_date='2026-05-01 00:00+00';
 IF (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SAL-WQ') IS NOT NULL THEN
   RAISE EXCEPTION 'private SeaFET replay restored pH suppressed via salinity dependency';
 END IF;
END $$;
-- Reinstating salinity releases the pH dependency correctly.
SELECT reinstate_sbe37_public_parameter(
  (SELECT rejection_id FROM rejected_observations WHERE source_table='seabird_sbe37'
    AND source_station='_IRL-SAL_SBE37' AND m_date='2026-05-01 00:00+00'
    AND public_parameter='salinity' AND active), 'reviewer','salinity corrected');
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM rejected_observations WHERE source_table IN ('seabird_sbe37','seabird_seafetv1')
              AND source_station IN ('_IRL-SAL_SBE37','_IRL-SAL_SEAFETV1') AND m_date='2026-05-01 00:00+00' AND active) THEN
   RAISE EXCEPTION 'reinstating salinity did not release its SeaFET pH dependency';
 END IF;
 UPDATE seabird_sbeeco SET salinity=32 WHERE station='IRL-SAL-WQ' AND m_date='2026-05-01 00:00+00';
 UPDATE seabird_seafetv1 SET ph_tempsal=8.15,qc_ph_tempsal=3 WHERE station='IRL-SAL-WQ' AND m_date='2026-05-01 00:00+00';
 IF (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SAL-WQ') <> 32
    OR (SELECT ph_tempsal FROM seabird_seafetv1 WHERE station='IRL-SAL-WQ') <> 8.15 THEN
   RAISE EXCEPTION 'reinstated salinity/pH still blocked normal replay';
 END IF;
END $$;

-- PRESSURE_WATER -> DEPTH_INSTRUMENT: the production writer sets
-- depth_instrument = pressure_water (sbe37_ascii/R/sbe37_ascii_process_recurring_final.R:2443),
-- documented as an enforced invariant in sbe37_ascii/docs/instrument_depth_updates.md.
INSERT INTO seabird_sbeeco VALUES ('IRL-PRS-WQ','2026-05-02 00:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz)
  VALUES ('_IRL-PRS_SBE37','2026-05-02 00:00+00','PRS-1',4000);
SELECT reject_sbe37_public_parameter('_IRL-PRS_SBE37','PRS-1','2026-05-02 00:00+00','pressure_water',2,'bad source pressure','tester','pressure dependency test');
DO $$
DECLARE v_pressure bigint := (SELECT rejection_id FROM rejected_observations
  WHERE source_table='seabird_sbe37' AND source_station='_IRL-PRS_SBE37'
    AND m_date='2026-05-02 00:00+00' AND public_parameter='pressure_water' AND active);
        v_depth bigint;
BEGIN
 IF v_pressure IS NULL THEN RAISE EXCEPTION 'pressure_water rejection was not recorded'; END IF;
 IF (SELECT pressure_water FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') IS NOT NULL
    OR (SELECT qc_pressure_water FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') <> 2 THEN
   RAISE EXCEPTION 'pressure_water rejection suppression failed';
 END IF;
 IF (SELECT depth_instrument FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') IS NOT NULL
    OR (SELECT qc_depth_instrument FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') <> 2 THEN
   RAISE EXCEPTION 'pressure_water rejection did not suppress dependent depth_instrument';
 END IF;
 v_depth := (SELECT rejection_id FROM rejected_observations WHERE parent_rejection_id=v_pressure AND public_parameter='depth_instrument' AND active);
 IF v_depth IS NULL THEN RAISE EXCEPTION 'pressure_water rejection did not create/audit a linked depth_instrument child'; END IF;
END $$;
DO $$ DECLARE v_pressure bigint := (SELECT rejection_id FROM rejected_observations
    WHERE source_table='seabird_sbe37' AND source_station='_IRL-PRS_SBE37'
      AND m_date='2026-05-02 00:00+00' AND public_parameter='pressure_water' AND active);
  v_depth bigint := (SELECT rejection_id FROM rejected_observations
    WHERE parent_rejection_id=(SELECT rejection_id FROM rejected_observations
      WHERE source_table='seabird_sbe37' AND source_station='_IRL-PRS_SBE37'
        AND m_date='2026-05-02 00:00+00' AND public_parameter='pressure_water' AND active)
    AND public_parameter='depth_instrument' AND active);
  v_allowed boolean := false;
BEGIN
 -- Child cannot be reinstated while pressure parent remains active.
 BEGIN
   PERFORM reinstate_sbe37_public_parameter(v_depth,'reviewer','direct child attempt');
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed OR NOT (SELECT active FROM rejected_observations WHERE rejection_id=v_depth) THEN
   RAISE EXCEPTION 'depth_instrument child was reinstated while pressure_water remained active';
 END IF;
 -- Public writer replay cannot restore depth_instrument.
 WITH identity AS MATERIALIZED (
   SELECT sbe37_set_public_write_identity('_IRL-PRS_SBE37', 'PRS-1')
 ), candidate AS MATERIALIZED (
   SELECT 'IRL-PRS-WQ'::varchar AS station, '2026-05-02 00:00+00'::timestamptz AS m_date,
          'SBE37/ECO'::varchar AS instrument, 5::double precision AS pressure_water, 5::double precision AS depth_instrument
 )
 INSERT INTO seabird_sbeeco (station, m_date, instrument, pressure_water, depth_instrument)
 SELECT c.station, c.m_date, c.instrument, c.pressure_water, c.depth_instrument FROM candidate c CROSS JOIN identity
 ON CONFLICT (station, m_date) DO UPDATE SET instrument=EXCLUDED.instrument, pressure_water=EXCLUDED.pressure_water, depth_instrument=EXCLUDED.depth_instrument;
 IF (SELECT pressure_water FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') IS NOT NULL
    OR (SELECT depth_instrument FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') IS NOT NULL THEN
   RAISE EXCEPTION 'public writer replay restored pressure_water/depth_instrument dependency';
 END IF;
 -- Private SBE37 replay cannot restore it.
 UPDATE seabird_sbe37 SET raw_conductivity_hz=4002 WHERE station='_IRL-PRS_SBE37' AND m_date='2026-05-02 00:00+00';
 IF (SELECT depth_instrument FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') IS NOT NULL THEN
   RAISE EXCEPTION 'private SBE37 replay restored depth_instrument suppressed via pressure dependency';
 END IF;
END $$;
-- Reinstating pressure releases the dependency correctly.
SELECT reinstate_sbe37_public_parameter(
  (SELECT rejection_id FROM rejected_observations WHERE source_table='seabird_sbe37'
    AND source_station='_IRL-PRS_SBE37' AND m_date='2026-05-02 00:00+00'
    AND public_parameter='pressure_water' AND active), 'reviewer','pressure corrected');
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM rejected_observations WHERE source_table='seabird_sbe37'
              AND source_station='_IRL-PRS_SBE37' AND m_date='2026-05-02 00:00+00' AND active) THEN
   RAISE EXCEPTION 'reinstating pressure_water did not release its depth_instrument dependency';
 END IF;
 UPDATE seabird_sbeeco SET pressure_water=6,depth_instrument=6 WHERE station='IRL-PRS-WQ' AND m_date='2026-05-02 00:00+00';
 IF (SELECT pressure_water FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') <> 6
    OR (SELECT depth_instrument FROM seabird_sbeeco WHERE station='IRL-PRS-WQ') <> 6 THEN
   RAISE EXCEPTION 'reinstated pressure_water/depth_instrument still blocked normal replay';
 END IF;
END $$;

-- The SBE37 API accepts precisely the columns implemented by its fixed public
-- CASE.  depth_instrument is intentionally omitted from the explicit list: it
-- is now a dependent of pressure_water (pressure_water -> depth_instrument),
-- so it is exercised here only via that cascade, and a direct, independent
-- depth_instrument rejection on the same row would correctly conflict with
-- pressure_water's already-active child under the source-observation unique
-- index.  Temperature is last because it derives salinity and dissolved oxygen.
INSERT INTO seabird_sbeeco VALUES ('IRL-ALLOW-WQ','2026-04-01 00:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz)
  VALUES ('_IRL-ALLOW_SBE37','2026-04-01 00:00+00','ALLOW-1',4000);
DO $$ DECLARE v_parameter varchar; BEGIN
 FOREACH v_parameter IN ARRAY ARRAY['conductivity','salinity','pressure_water',
                                    'oxygen_saturation_perc','dissolved_oxygen','specific_conductance',
                                    'temperature_water'] LOOP
   PERFORM reject_sbe37_public_parameter('_IRL-ALLOW_SBE37','ALLOW-1','2026-04-01 00:00+00',v_parameter,2,'allowlist test','tester');
 END LOOP;
 -- Seven explicit rejections plus pressure_water's implicit depth_instrument
 -- child together cover all eight supported parameters for this row.
 IF (SELECT count(*) FROM rejected_observations WHERE source_table='seabird_sbe37'
       AND source_station='_IRL-ALLOW_SBE37' AND active) <> 8 THEN
   RAISE EXCEPTION 'not all eight supported SBE37 parameters were accepted';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM rejected_observations WHERE source_table='seabird_sbe37'
       AND source_station='_IRL-ALLOW_SBE37' AND public_parameter='depth_instrument' AND active) THEN
   RAISE EXCEPTION 'pressure_water rejection did not implicitly cover depth_instrument';
 END IF;
END $$;

-- Unsupported and misspelled API requests fail before inserting a registry row
-- or changing the public value.
INSERT INTO seabird_sbeeco VALUES ('IRL-BAD-WQ','2026-04-01 01:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz)
  VALUES ('_IRL-BAD_SBE37','2026-04-01 01:00+00','BAD-1',4000);
DO $$ DECLARE v_parameter varchar; v_allowed boolean; BEGIN
 FOREACH v_parameter IN ARRAY ARRAY['unsupported_parameter','temprature_water'] LOOP
   v_allowed := false;
   BEGIN
     PERFORM reject_sbe37_public_parameter('_IRL-BAD_SBE37','BAD-1','2026-04-01 01:00+00',v_parameter,1,'invalid parameter test','tester');
     v_allowed := true;
   EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
   END;
   IF v_allowed THEN RAISE EXCEPTION 'unsupported SBE37 parameter % was accepted', v_parameter; END IF;
   IF EXISTS (SELECT 1 FROM rejected_observations WHERE source_table='seabird_sbe37'
                AND source_station='_IRL-BAD_SBE37' AND public_parameter=v_parameter) THEN
     RAISE EXCEPTION 'invalid SBE37 parameter % created a registry row', v_parameter;
   END IF;
   IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-BAD-WQ' AND m_date='2026-04-01 01:00+00') <> 4 THEN
     RAISE EXCEPTION 'invalid SBE37 parameter % changed the public row', v_parameter;
   END IF;
 END LOOP;
END $$;

-- Direct/manual insertion bypasses the API, so both public replay and private
-- reapply paths must fail closed rather than silently ignoring an invalid name.
INSERT INTO seabird_sbeeco VALUES ('IRL-DEF-WQ','2026-04-01 02:00+00','SBE37/ECO',4,3,30,3,20,3,1,3,1,3,90,3,8,3,4000,3);
INSERT INTO seabird_sbe37 (station,m_date,serial_number_sbe37,raw_conductivity_hz)
  VALUES ('_IRL-DEF_SBE37','2026-04-01 02:00+00','DEF-1',4000);
INSERT INTO rejected_observations
  (source_table,source_row_id,public_table,source_station,public_station,instrument_type,
   instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
VALUES ('seabird_sbe37',(SELECT row_id FROM seabird_sbe37 WHERE station='_IRL-DEF_SBE37' AND m_date='2026-04-01 02:00+00'),
        'seabird_sbeeco','_IRL-DEF_SBE37','IRL-DEF-WQ','SBE37','DEF-1',
        '2026-04-01 02:00+00','unsupported_parameter',1,'defensive guard test','tester');
DO $$ DECLARE v_allowed boolean := false; BEGIN
 BEGIN
   UPDATE seabird_sbeeco SET conductivity=5 WHERE station='IRL-DEF-WQ' AND m_date='2026-04-01 02:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed OR (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-DEF-WQ' AND m_date='2026-04-01 02:00+00') <> 4 THEN
   RAISE EXCEPTION 'SBE37 guard did not fail closed for direct invalid registry row';
 END IF;
 v_allowed := false;
 BEGIN
   UPDATE seabird_sbe37 SET raw_conductivity_hz=4001 WHERE station='_IRL-DEF_SBE37' AND m_date='2026-04-01 02:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed OR (SELECT raw_conductivity_hz FROM seabird_sbe37 WHERE station='_IRL-DEF_SBE37' AND m_date='2026-04-01 02:00+00') <> 4000 THEN
   RAISE EXCEPTION 'SBE37 private reapply did not fail closed for direct invalid registry row';
 END IF;
END $$;
ROLLBACK;
