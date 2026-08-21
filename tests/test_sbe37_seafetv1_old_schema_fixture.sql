\set ON_ERROR_STOP on
-- Schema required before installing the committed pre-hardening modules.
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
