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
CREATE TABLE seabird_sbe37 (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_sbe37 varchar, raw_conductivity_hz double precision, UNIQUE(station,m_date));
CREATE TABLE seabird_seafetv1 (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_seafet varchar,
  ph_tempsal double precision, qc_ph_tempsal integer, ph_int double precision, UNIQUE(station,m_date));
CREATE TABLE seabird_sunav2 (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_suna varchar,
  nitrate_um double precision, qc_nitrate_um integer, nitrate_mgl double precision, qc_nitrate_mgl integer, UNIQUE(station,m_date));
CREATE TABLE nortek_aquadopp (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_aquadopp varchar,
  current_speed double precision, qc_current_speed integer, current_direction double precision, qc_current_direction integer, UNIQUE(station,m_date));
\ir ../sql/sbe37_public_parameter_suppression.sql
\ir ../sql/seafetv1/public_parameter_suppression.sql
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

-- The generic registry enforces active uniqueness for serial-bearing sources.
DO $$ DECLARE v_inserted boolean := false; BEGIN
 BEGIN
   INSERT INTO rejected_observations
     (source_table,public_table,source_station,public_station,instrument_type,
      instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
   VALUES
     ('seabird_sbe37','seabird_sbeeco','_IRL-SB_SBE37','IRL-SB-WQ','SBE37',
      '25799','2026-01-01 00:00+00','conductivity',2,'duplicate test','tester');
   v_inserted := true;
 EXCEPTION WHEN unique_violation THEN NULL;
 END;
 IF v_inserted THEN RAISE EXCEPTION 'active serial rejection duplicate was accepted'; END IF;
END $$;

-- The generic registry needs no SBE37-specific schema values or parameter list,
-- but every active instrument identity carries its serial number.
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

-- A source row without its serial is incomplete; it cannot create a separate,
-- serial-less rejection identity.
DO $$ DECLARE v_inserted boolean := false; BEGIN
 BEGIN
   INSERT INTO rejected_observations
     (source_table,public_table,source_station,public_station,instrument_type,
      instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by)
   VALUES
     ('missing_serial_fixture','fixture_public','IRL-MISS-SRC','IRL-MISS-PUB',
      'Fixture',NULL,'2026-01-01 00:00+00','fixture_parameter',2,
      'missing serial test','tester');
   v_inserted := true;
 EXCEPTION WHEN not_null_violation THEN NULL;
 END;
 IF v_inserted THEN RAISE EXCEPTION 'missing instrument serial was accepted'; END IF;
END $$;

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

-- A public-only/manual SQL attempt with no private identity fails closed.
RESET irlon.sbe37_source_station;
RESET irlon.sbe37_serial_number;
DO $$ DECLARE v_allowed boolean := false; BEGIN
 BEGIN
   UPDATE seabird_sbeeco SET conductivity=99 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed THEN RAISE EXCEPTION 'missing identity unexpectedly allowed'; END IF;
 IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS NOT NULL THEN RAISE EXCEPTION 'identity-less bypass repopulated value'; END IF;
END $$;

-- Unrelated private station, fabricated serial, and absent private timestamp
-- cannot authorize the active-rejection public row.
DO $$ DECLARE v_allowed boolean; BEGIN
 v_allowed := false;
 BEGIN
   PERFORM sbe37_set_public_write_identity('_IRL-OTHER_SBE37','25799');
   UPDATE seabird_sbeeco SET conductivity=99 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed THEN RAISE EXCEPTION 'unrelated station unexpectedly allowed'; END IF;
 v_allowed := false;
 BEGIN
   PERFORM sbe37_set_public_write_identity('_IRL-SB_SBE37','fabricated');
   UPDATE seabird_sbeeco SET conductivity=99 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
   v_allowed := true;
 EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL;
 END;
 IF v_allowed THEN RAISE EXCEPTION 'fabricated serial unexpectedly allowed'; END IF;
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
 IF v_allowed OR (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS NOT NULL THEN
   RAISE EXCEPTION 'identity leaked into later public write';
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
DO $$ BEGIN IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 8 THEN RAISE EXCEPTION 'different serial was suppressed'; END IF; END $$;

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
 IF v_allowed THEN RAISE EXCEPTION 'mismatched single statement unexpectedly allowed'; END IF;
 IF (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') IS DISTINCT FROM v_before THEN RAISE EXCEPTION 'failed statement was partial'; END IF;
END $$;

-- Reinstatement is audited and permits a future write; it does not reconstruct history.
SELECT reinstate_sbe37_public_parameter((SELECT rejection_id FROM rejected_observations WHERE source_table='seabird_sbe37'),'reviewer','validated correction');
SELECT sbe37_set_public_write_identity('_IRL-SB_SBE37','25799');
UPDATE seabird_sbeeco SET conductivity=6 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
DO $$ BEGIN IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 6 OR (SELECT active FROM rejected_observations WHERE source_table='seabird_sbe37') THEN RAISE EXCEPTION 'reinstatement failed'; END IF; END $$;

-- The rejection API is atomic under rollback.
SAVEPOINT rejection_rollback;
SELECT reject_sbe37_public_parameter('_IRL-SB_SBE37','25799','2026-01-01 00:00+00','salinity',1,'rollback','tester');
ROLLBACK TO rejection_rollback;
DO $$ BEGIN IF (SELECT count(*) FROM rejected_observations WHERE source_table='seabird_sbe37') <> 1 OR (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 31 THEN RAISE EXCEPTION 'rollback was partial'; END IF; END $$;

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

INSERT INTO seabird_sunav2 VALUES ('_IRL-SF_SUNA','2026-02-01 00:00+00','SU-1',NULL,NULL,NULL,NULL),('IRL-SF-WQ','2026-02-01 00:00+00',NULL,10,3,2,3);
SELECT reject_sunav2_public_parameter('_IRL-SF_SUNA','SU-1','2026-02-01 00:00+00','nitrate_um',2,'test','tester');
UPDATE seabird_sunav2 SET nitrate_um=11,qc_nitrate_um=3,nitrate_mgl=2.1 WHERE station='IRL-SF-WQ' AND m_date='2026-02-01 00:00+00';
DO $$ BEGIN IF (SELECT nitrate_um FROM seabird_sunav2 WHERE station='IRL-SF-WQ') IS NOT NULL OR (SELECT qc_nitrate_um FROM seabird_sunav2 WHERE station='IRL-SF-WQ')<>2 OR (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-SF-WQ')<>2.1 THEN RAISE EXCEPTION 'SUNA fixed-parameter guard failed'; END IF; END $$;
DO $$ DECLARE ok boolean:=false; BEGIN BEGIN PERFORM reject_sunav2_public_parameter('_IRL-SF_SUNA','fabricated','2026-02-01 00:00+00','nitrate_mgl',3,'test','tester'); ok:=true; EXCEPTION WHEN others THEN NULL; END; IF ok THEN RAISE EXCEPTION 'SUNA fabricated serial accepted'; END IF; END $$;
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
ROLLBACK;
