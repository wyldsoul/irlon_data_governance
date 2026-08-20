\set ON_ERROR_STOP on
-- Disposable SUNA staging simulation.  The fixture values were read from
-- production with default_transaction_read_only=on on 2026-08-19; no live row
-- is used by this test.  The represented production objects are documented in
-- docs/SUNAV2_STAGING_VALIDATION.md.
BEGIN;
CREATE SCHEMA sunav2_realistic_staging;
SET LOCAL search_path TO sunav2_realistic_staging;

-- Minimal supporting SBE fixtures needed only because the generic registry SQL
-- currently also defines the SBE37 module.
CREATE TABLE seabird_sbe37 (station varchar NOT NULL, m_date timestamptz NOT NULL, serial_number_sbe37 varchar, raw_conductivity_hz double precision, row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, UNIQUE(station,m_date));
CREATE TABLE seabird_sbeeco (station varchar NOT NULL, m_date timestamptz NOT NULL, instrument varchar, conductivity double precision, qc_conductivity integer, salinity double precision, qc_salinity integer, temperature_water double precision, qc_temperature_water integer, pressure_water double precision, qc_pressure_water integer, depth_instrument double precision, qc_depth_instrument integer, oxygen_saturation_perc double precision, qc_oxygen_saturation_perc integer, dissolved_oxygen double precision, qc_dissolved_oxygen integer, specific_conductance double precision, qc_specific_conductance integer, UNIQUE(station,m_date));

-- Production-equivalent SUNA details relevant to its writer and archive
-- trigger: row-id default, nullable operational columns, station FK, the
-- station/timestamp unique key, and the station/depth/timestamp index.
CREATE TABLE station (name varchar PRIMARY KEY);
CREATE SEQUENCE seabird_sunav2_row_id_seq;
CREATE TABLE seabird_sunav2 (
  row_id integer NOT NULL DEFAULT nextval('seabird_sunav2_row_id_seq'),
  entry_date timestamptz DEFAULT now(), m_date timestamptz, station varchar,
  depth double precision, serial_number_suna varchar,
  nitrate_um double precision, qc_nitrate_um integer,
  nitrate_mgl double precision, qc_nitrate_mgl integer,
  lamp_voltage double precision, nitrate_tempsal_um double precision,
  nitrate_tempsal_plant_um double precision, absorbance_254nm double precision,
  absorbance_350nm double precision, spectrum_average double precision,
  dark_value_used_for_fit double precision, integration_time_factor double precision,
  internal_temperature double precision, spectrometer_temperature double precision,
  lamp_temperature double precision, cumulative_lamp_on_time double precision,
  relative_humidity_suna double precision, main_voltage double precision,
  fit_rmse double precision, internal_voltage double precision, calfile_suna varchar,
  time_suna varchar, date_suna varchar,
  CONSTRAINT seabird_sunav2_row_id_key UNIQUE(row_id),
  CONSTRAINT seabird_sunav2_station_fkey FOREIGN KEY(station) REFERENCES station(name),
  CONSTRAINT suna_unique_station_m_date UNIQUE(station,m_date)
);
CREATE INDEX seabird_sunav2__station_depth_m_date ON seabird_sunav2(station,depth,m_date);
CREATE SEQUENCE seabird_sunav2_archive_archive_id_seq;
CREATE TABLE seabird_sunav2_archive (
  archive_id integer NOT NULL DEFAULT nextval('seabird_sunav2_archive_archive_id_seq'),
  archived_at timestamp without time zone DEFAULT now(), row_id integer NOT NULL,
  entry_date timestamptz, m_date timestamptz, station varchar, lamp_voltage double precision,
  nitrate_tempsal_um double precision, nitrate_tempsal_plant_um double precision,
  nitrate_um double precision, nitrate_mgl double precision, absorbance_254nm double precision,
  absorbance_350nm double precision, spectrum_average double precision,
  dark_value_used_for_fit double precision, integration_time_factor double precision,
  internal_temperature double precision, spectrometer_temperature double precision,
  lamp_temperature double precision, cumulative_lamp_on_time double precision,
  relative_humidity_suna double precision, main_voltage double precision, fit_rmse double precision,
  internal_voltage double precision, calfile_suna varchar, serial_number_suna varchar,
  time_suna varchar, date_suna varchar, PRIMARY KEY(archive_id)
);
CREATE INDEX seabird_sunav2_archive_station_depth_m_date_idx ON seabird_sunav2_archive(station,m_date);

-- Exact production archive gate and OLD-row payload shape, represented against
-- the relevant subset of actual production columns.
CREATE FUNCTION seabird_sunav2_archive_trigger() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('application_name') = 'suna_ascii_process_recurring_final.R' THEN
    INSERT INTO seabird_sunav2_archive(
      row_id,entry_date,m_date,station,lamp_voltage,nitrate_tempsal_um,nitrate_tempsal_plant_um,
      nitrate_um,nitrate_mgl,absorbance_254nm,absorbance_350nm,spectrum_average,
      dark_value_used_for_fit,integration_time_factor,internal_temperature,
      spectrometer_temperature,lamp_temperature,cumulative_lamp_on_time,
      relative_humidity_suna,main_voltage,fit_rmse,internal_voltage,calfile_suna,
      serial_number_suna,time_suna,date_suna)
    VALUES (OLD.row_id,OLD.entry_date,OLD.m_date,OLD.station,OLD.lamp_voltage,
      OLD.nitrate_tempsal_um,OLD.nitrate_tempsal_plant_um,OLD.nitrate_um,OLD.nitrate_mgl,
      OLD.absorbance_254nm,OLD.absorbance_350nm,OLD.spectrum_average,
      OLD.dark_value_used_for_fit,OLD.integration_time_factor,OLD.internal_temperature,
      OLD.spectrometer_temperature,OLD.lamp_temperature,OLD.cumulative_lamp_on_time,
      OLD.relative_humidity_suna,OLD.main_voltage,OLD.fit_rmse,OLD.internal_voltage,
      OLD.calfile_suna,OLD.serial_number_suna,OLD.time_suna,OLD.date_suna);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER archive_trigger_sunav2 BEFORE UPDATE ON seabird_sunav2 FOR EACH ROW EXECUTE FUNCTION seabird_sunav2_archive_trigger();

\ir ../../sql/sbe37_public_parameter_suppression.sql
\ir ../../sql/sunav2/public_parameter_suppression.sql

-- Copied fixture identity: _IRL-VB_SUNA / 612 / 2026-08-19 20:00 UTC.
INSERT INTO station VALUES ('_IRL-VB_SUNA'),('IRL-VB-WQ');
SET LOCAL application_name = 'suna_ascii_tscorrection_recurring_final.R';
-- A. Same private-first/public-upsert shape as the recurring writer.
INSERT INTO seabird_sunav2 (m_date,station,depth,serial_number_suna,nitrate_tempsal_um)
VALUES ('2026-08-19 20:00+00','_IRL-VB_SUNA',0,'612',1.0992857142857)
ON CONFLICT(station,m_date) DO UPDATE SET serial_number_suna=EXCLUDED.serial_number_suna,nitrate_tempsal_um=EXCLUDED.nitrate_tempsal_um;
INSERT INTO seabird_sunav2 (m_date,station,depth,nitrate_um,qc_nitrate_um,nitrate_mgl,qc_nitrate_mgl)
VALUES ('2026-08-19 20:00+00','IRL-VB-WQ',0,1.0992857142857,3,0.015378571428571,3)
ON CONFLICT(station,m_date) DO UPDATE SET nitrate_um=EXCLUDED.nitrate_um,qc_nitrate_um=EXCLUDED.qc_nitrate_um,nitrate_mgl=EXCLUDED.nitrate_mgl,qc_nitrate_mgl=EXCLUDED.qc_nitrate_mgl;
DO $$ BEGIN
 IF (SELECT serial_number_suna FROM seabird_sunav2 WHERE station='_IRL-VB_SUNA')<>'612'
 OR (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-VB-WQ')<>0.015378571428571
 OR (SELECT count(*) FROM seabird_sunav2_archive)<>0 THEN RAISE EXCEPTION 'normal SUNA baseline failed'; END IF;
END $$;

-- B/C/D/E. Rejection, recurring-writer-shaped replay, direct public replay,
-- and private replay all preserve private data and the active suppression.
SELECT reject_sunav2_public_parameter('_IRL-VB_SUNA','612','2026-08-19 20:00+00','nitrate_mgl',2,'staging-only SUNA suppression test','staging');
DO $$ BEGIN
 IF (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-VB-WQ') IS NOT NULL
 OR (SELECT qc_nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-VB-WQ')<>2
 OR (SELECT nitrate_um FROM seabird_sunav2 WHERE station='IRL-VB-WQ')<>1.0992857142857
 OR (SELECT serial_number_suna FROM seabird_sunav2 WHERE station='_IRL-VB_SUNA')<>'612'
 OR sunav2_count_active_rejections('_IRL-VB_SUNA','612','2026-08-19 20:00+00')<>1 THEN RAISE EXCEPTION 'SUNA rejection failed'; END IF;
END $$;
INSERT INTO seabird_sunav2(m_date,station,depth,nitrate_um,qc_nitrate_um,nitrate_mgl,qc_nitrate_mgl)
VALUES ('2026-08-19 20:00+00','IRL-VB-WQ',0,1.0992857142857,3,0.015378571428571,3)
ON CONFLICT(station,m_date) DO UPDATE SET nitrate_um=EXCLUDED.nitrate_um,qc_nitrate_um=EXCLUDED.qc_nitrate_um,nitrate_mgl=EXCLUDED.nitrate_mgl,qc_nitrate_mgl=EXCLUDED.qc_nitrate_mgl;
UPDATE seabird_sunav2 SET nitrate_mgl=0.015378571428571,qc_nitrate_mgl=3 WHERE station='IRL-VB-WQ';
UPDATE seabird_sunav2 SET nitrate_tempsal_um=1.0992857142857 WHERE station='_IRL-VB_SUNA';
DO $$ BEGIN
 IF (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-VB-WQ') IS NOT NULL
 OR (SELECT qc_nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-VB-WQ')<>2
 OR (SELECT count(*) FROM seabird_sunav2_archive)<>0 THEN RAISE EXCEPTION 'SUNA replay or current archive gate failed'; END IF;
END $$;

-- The historic archive gate archives OLD rows. It exposes repeated active
-- replay as separate archive rows; this is deliberately measured, not hidden.
SET LOCAL application_name = 'suna_ascii_process_recurring_final.R';
UPDATE seabird_sunav2 SET nitrate_mgl=0.015378571428571,qc_nitrate_mgl=3 WHERE station='IRL-VB-WQ';
UPDATE seabird_sunav2 SET nitrate_tempsal_um=1.0992857142857 WHERE station='_IRL-VB_SUNA';
DO $$ BEGIN
 IF (SELECT count(*) FROM seabird_sunav2_archive)<>3
 OR (SELECT nitrate_mgl FROM seabird_sunav2_archive ORDER BY archive_id LIMIT 1) IS NOT NULL
 THEN RAISE EXCEPTION 'SUNA archive behavior was not represented'; END IF;
END $$;

-- F. Reinstatement is metadata-only; the next legitimate public upsert restores.
SELECT reinstate_sunav2_public_parameter('_IRL-VB_SUNA','612','2026-08-19 20:00+00','nitrate_mgl','staging','staging complete');
DO $$ BEGIN IF (SELECT active FROM rejected_observations WHERE source_station='_IRL-VB_SUNA') OR (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-VB-WQ') IS NOT NULL THEN RAISE EXCEPTION 'SUNA reinstatement semantics failed'; END IF; END $$;
INSERT INTO seabird_sunav2(m_date,station,depth,nitrate_um,qc_nitrate_um,nitrate_mgl,qc_nitrate_mgl)
VALUES ('2026-08-19 20:00+00','IRL-VB-WQ',0,1.0992857142857,3,0.015378571428571,3)
ON CONFLICT(station,m_date) DO UPDATE SET nitrate_um=EXCLUDED.nitrate_um,qc_nitrate_um=EXCLUDED.qc_nitrate_um,nitrate_mgl=EXCLUDED.nitrate_mgl,qc_nitrate_mgl=EXCLUDED.qc_nitrate_mgl;
DO $$ BEGIN IF (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-VB-WQ')<>0.015378571428571 THEN RAISE EXCEPTION 'SUNA post-reinstatement replay failed'; END IF; END $$;

-- G. A failed rejection is fully rolled back, including its attempted archive.
SAVEPOINT failed_rejection;
SELECT reject_sunav2_public_parameter('_IRL-VB_SUNA','612','2026-08-19 20:00+00','nitrate_mgl',1,'rollback test','staging');
ROLLBACK TO failed_rejection;
DO $$ BEGIN
 IF (SELECT count(*) FROM rejected_observations WHERE source_station='_IRL-VB_SUNA' AND active)<>0
 OR (SELECT nitrate_mgl FROM seabird_sunav2 WHERE station='IRL-VB-WQ')<>0.015378571428571
 OR (SELECT count(*) FROM seabird_sunav2_archive)<>4 THEN RAISE EXCEPTION 'SUNA rollback was partial'; END IF;
END $$;
ROLLBACK;
