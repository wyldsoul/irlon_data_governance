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
\ir ../sql/sbe37_public_parameter_suppression.sql

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
SELECT reinstate_sbe37_public_parameter((SELECT rejection_id FROM rejected_observations),'reviewer','validated correction');
SELECT sbe37_set_public_write_identity('_IRL-SB_SBE37','25799');
UPDATE seabird_sbeeco SET conductivity=6 WHERE station='IRL-SB-WQ' AND m_date='2026-01-01 00:00+00';
DO $$ BEGIN IF (SELECT conductivity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 6 OR (SELECT active FROM rejected_observations) THEN RAISE EXCEPTION 'reinstatement failed'; END IF; END $$;

-- The rejection API is atomic under rollback.
SAVEPOINT rejection_rollback;
SELECT reject_sbe37_public_parameter('_IRL-SB_SBE37','25799','2026-01-01 00:00+00','salinity',1,'rollback','tester');
ROLLBACK TO rejection_rollback;
DO $$ BEGIN IF (SELECT count(*) FROM rejected_observations) <> 1 OR (SELECT salinity FROM seabird_sbeeco WHERE station='IRL-SB-WQ') <> 31 THEN RAISE EXCEPTION 'rollback was partial'; END IF; END $$;
ROLLBACK;
