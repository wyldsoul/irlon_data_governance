-- READ-ONLY preflight for the proposed SBE37 governance deployment.
-- Run manually with a role that can inspect the target database.  This file
-- deliberately opens a READ ONLY transaction and ends with ROLLBACK.
\set ON_ERROR_STOP on
BEGIN READ ONLY;

SELECT current_database() AS database_name,
       current_user AS connected_role,
       current_setting('default_transaction_read_only') AS default_read_only,
       now() AS checked_at;

SELECT c.relname AS table_name,
       string_agg(a.attname || ':' || pg_catalog.format_type(a.atttypid,a.atttypmod),
                  ', ' ORDER BY a.attnum) AS required_columns
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  JOIN pg_attribute a ON a.attrelid=c.oid
 WHERE n.nspname='public'
   AND c.relname IN ('seabird_sbe37','seabird_sbeeco','seabird_seafetv1')
   AND a.attnum > 0 AND NOT a.attisdropped
   AND a.attname IN ('row_id','station','m_date','serial_number_sbe37',
                     'serial_number_seafet','instrument','conductivity',
                     'salinity','temperature_water','pressure_water',
                     'depth_instrument','oxygen_saturation_perc',
                     'dissolved_oxygen','specific_conductance','ph_tempsal',
                     'qc_conductivity','qc_salinity','qc_temperature_water',
                     'qc_pressure_water','qc_depth_instrument',
                     'qc_oxygen_saturation_perc','qc_dissolved_oxygen',
                     'qc_specific_conductance','qc_ph_tempsal')
 GROUP BY c.relname
 ORDER BY c.relname;

SELECT c.relname AS table_name, con.conname, pg_get_constraintdef(con.oid) AS definition
  FROM pg_constraint con
  JOIN pg_class c ON c.oid=con.conrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public'
   AND c.relname IN ('seabird_sbe37','seabird_sbeeco','seabird_seafetv1')
   AND pg_get_constraintdef(con.oid) ILIKE '%UNIQUE%'
 ORDER BY c.relname, con.conname;

SELECT c.relname AS table_name,
       COALESCE(string_agg(t.tgname || ' -> ' || p.proname, E'\n' ORDER BY t.tgname)
                FILTER (WHERE NOT t.tgisinternal), '(none)') AS noninternal_triggers
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  LEFT JOIN pg_trigger t ON t.tgrelid=c.oid
  LEFT JOIN pg_proc p ON p.oid=t.tgfoid
 WHERE n.nspname='public'
   AND c.relname IN ('seabird_sbe37','seabird_sbeeco','seabird_seafetv1')
 GROUP BY c.relname
 ORDER BY c.relname;

SELECT CASE WHEN to_regclass('public.rejected_observations') IS NULL
            THEN 'PASS: rejected_observations is absent; first deployment is possible'
            ELSE 'STOP: rejected_observations already exists; compare its DDL before proceeding'
       END AS registry_preflight;

SELECT p.proname AS existing_governance_function
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public'
   AND (p.proname LIKE 'sbe37\_%' ESCAPE '\'
        OR p.proname LIKE 'seafetv1\_%' ESCAPE '\')
 ORDER BY p.proname;

ROLLBACK;
