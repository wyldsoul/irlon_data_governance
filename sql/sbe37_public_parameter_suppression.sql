-- SBE37 public-parameter suppression module.  The generic registry is in
-- rejected_observations_schema.sql and must be installed first on a clean
-- schema.  This module is safely reapplicable to an existing compatible
-- registry: functions are replaced and its triggers are recreated.
--
-- This script deliberately leaves seabird_sbe37 (private/raw) unchanged.

-- Maps the actual private naming convention, e.g. _IRL-SB_SBE37 -> IRL-SB-WQ.
CREATE OR REPLACE FUNCTION sbe37_public_station(p_source_station varchar)
RETURNS varchar LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT regexp_replace(p_source_station, '^_(.+)_SBE37$', '\1-WQ')
$$;

CREATE OR REPLACE FUNCTION sbe37_source_station(p_public_station varchar)
RETURNS varchar LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE WHEN p_public_station ~ '^.+-WQ$'
      THEN '_' || regexp_replace(p_public_station, '-WQ$', '') || '_SBE37' END
$$;

CREATE OR REPLACE FUNCTION sbe37_set_public_write_identity(
    p_source_station varchar,
    p_serial_number_sbe37 varchar)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF sbe37_public_station(p_source_station) = p_source_station THEN
        RAISE EXCEPTION 'not an SBE37 private station: %', p_source_station;
    END IF;
    PERFORM set_config('irlon.sbe37_source_station', p_source_station, true);
    PERFORM set_config('irlon.sbe37_serial_number', p_serial_number_sbe37, true);
END;
$$;

-- Writer-facing, read-only reporting hook: call once per candidate public row
-- using the same private identity supplied to sbe37_set_public_write_identity.
CREATE OR REPLACE FUNCTION sbe37_count_active_rejections(
    p_source_station varchar, p_serial_number_sbe37 varchar,
    p_m_date timestamp with time zone)
RETURNS integer LANGUAGE sql STABLE AS $$
    SELECT count(*)::integer
      FROM rejected_observations
     WHERE active AND source_table = 'seabird_sbe37'
       AND public_table = 'seabird_sbeeco' AND instrument_type = 'SBE37'
       AND source_station = p_source_station
       AND m_date = p_m_date
$$;

-- Applies every matching active decision to a public row.  The fixed CASE is
-- intentional: it is auditable and avoids dynamic SQL over a column name.
CREATE OR REPLACE FUNCTION sbe37_apply_active_rejections(
    p_source_station varchar,
    p_serial_number_sbe37 varchar,
    p_m_date timestamp with time zone)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_count integer;
BEGIN
    IF EXISTS (
        SELECT 1 FROM rejected_observations
         WHERE active AND source_table='seabird_sbe37'
           AND public_table='seabird_sbeeco' AND instrument_type='SBE37'
           AND source_station=p_source_station AND m_date=p_m_date
           AND public_parameter NOT IN ('conductivity', 'salinity', 'temperature_water',
                                        'pressure_water', 'depth_instrument',
                                        'oxygen_saturation_perc', 'dissolved_oxygen',
                                        'specific_conductance')
    ) THEN
        RAISE EXCEPTION 'unsupported active SBE37 public parameter exists for % / %', p_source_station, p_m_date;
    END IF;
    v_count := sbe37_count_active_rejections(
        p_source_station, p_serial_number_sbe37, p_m_date);
    -- Avoid a public UPDATE (and its existing archive trigger) for every
    -- ordinary private/raw write.
    IF v_count = 0 THEN RETURN 0; END IF;
    UPDATE seabird_sbeeco AS p
       SET conductivity = CASE WHEN r.conductivity THEN NULL ELSE p.conductivity END,
           qc_conductivity = CASE WHEN r.conductivity THEN r.conductivity_qc ELSE p.qc_conductivity END,
           salinity = CASE WHEN r.salinity THEN NULL ELSE p.salinity END,
           qc_salinity = CASE WHEN r.salinity THEN r.salinity_qc ELSE p.qc_salinity END,
           temperature_water = CASE WHEN r.temperature_water THEN NULL ELSE p.temperature_water END,
           qc_temperature_water = CASE WHEN r.temperature_water THEN r.temperature_water_qc ELSE p.qc_temperature_water END,
           pressure_water = CASE WHEN r.pressure_water THEN NULL ELSE p.pressure_water END,
           qc_pressure_water = CASE WHEN r.pressure_water THEN r.pressure_water_qc ELSE p.qc_pressure_water END,
           depth_instrument = CASE WHEN r.depth_instrument THEN NULL ELSE p.depth_instrument END,
           qc_depth_instrument = CASE WHEN r.depth_instrument THEN r.depth_instrument_qc ELSE p.qc_depth_instrument END,
           oxygen_saturation_perc = CASE WHEN r.oxygen_saturation_perc THEN NULL ELSE p.oxygen_saturation_perc END,
           qc_oxygen_saturation_perc = CASE WHEN r.oxygen_saturation_perc THEN r.oxygen_saturation_perc_qc ELSE p.qc_oxygen_saturation_perc END,
           dissolved_oxygen = CASE WHEN r.dissolved_oxygen THEN NULL ELSE p.dissolved_oxygen END,
           qc_dissolved_oxygen = CASE WHEN r.dissolved_oxygen THEN r.dissolved_oxygen_qc ELSE p.qc_dissolved_oxygen END,
           specific_conductance = CASE WHEN r.specific_conductance THEN NULL ELSE p.specific_conductance END,
           qc_specific_conductance = CASE WHEN r.specific_conductance THEN r.specific_conductance_qc ELSE p.qc_specific_conductance END
      FROM (
          SELECT bool_or(public_parameter = 'conductivity') AS conductivity, max(qc_flag) FILTER (WHERE public_parameter = 'conductivity') AS conductivity_qc,
                 bool_or(public_parameter = 'salinity') AS salinity, max(qc_flag) FILTER (WHERE public_parameter = 'salinity') AS salinity_qc,
                 bool_or(public_parameter = 'temperature_water') AS temperature_water, max(qc_flag) FILTER (WHERE public_parameter = 'temperature_water') AS temperature_water_qc,
                 bool_or(public_parameter = 'pressure_water') AS pressure_water, max(qc_flag) FILTER (WHERE public_parameter = 'pressure_water') AS pressure_water_qc,
                 bool_or(public_parameter = 'depth_instrument') AS depth_instrument, max(qc_flag) FILTER (WHERE public_parameter = 'depth_instrument') AS depth_instrument_qc,
                 bool_or(public_parameter = 'oxygen_saturation_perc') AS oxygen_saturation_perc, max(qc_flag) FILTER (WHERE public_parameter = 'oxygen_saturation_perc') AS oxygen_saturation_perc_qc,
                 bool_or(public_parameter = 'dissolved_oxygen') AS dissolved_oxygen, max(qc_flag) FILTER (WHERE public_parameter = 'dissolved_oxygen') AS dissolved_oxygen_qc,
                 bool_or(public_parameter = 'specific_conductance') AS specific_conductance, max(qc_flag) FILTER (WHERE public_parameter = 'specific_conductance') AS specific_conductance_qc
            FROM rejected_observations
           WHERE active AND source_table = 'seabird_sbe37'
             AND public_table = 'seabird_sbeeco' AND instrument_type = 'SBE37'
             AND source_station = p_source_station
             AND m_date = p_m_date
      ) AS r
     WHERE p.station = sbe37_public_station(p_source_station) AND p.m_date = p_m_date;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- The only supported rejection operation.  The registry insert and public NULL
-- update are one SQL statement and therefore one transaction.
CREATE OR REPLACE FUNCTION reject_sbe37_public_parameter(
    p_source_station varchar, p_serial_number_sbe37 varchar,
    p_m_date timestamp with time zone, p_public_parameter varchar,
    p_qc_flag integer, p_rejection_reason varchar,
    p_rejected_by varchar DEFAULT current_user, p_source_query_or_script text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_rejection_id bigint;
BEGIN
    IF p_public_parameter NOT IN ('conductivity', 'salinity', 'temperature_water',
                                  'pressure_water', 'depth_instrument',
                                  'oxygen_saturation_perc', 'dissolved_oxygen',
                                  'specific_conductance') THEN
        RAISE EXCEPTION 'unsupported SBE37 public parameter: %', p_public_parameter
          USING HINT = 'Use one of conductivity, salinity, temperature_water, pressure_water, depth_instrument, oxygen_saturation_perc, dissolved_oxygen, specific_conductance.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM seabird_sbe37 s WHERE s.station = p_source_station AND s.m_date = p_m_date) THEN
        RAISE EXCEPTION 'private SBE37 observation not found: % / %', p_source_station, p_m_date;
    END IF;
    INSERT INTO rejected_observations
        (source_table, source_row_id, public_table, source_station, public_station, instrument_type,
         instrument_serial, m_date, public_parameter, qc_flag, rejection_reason,
         rejected_by, source_query_or_script)
    VALUES ('seabird_sbe37',
            (SELECT row_id::bigint FROM seabird_sbe37 WHERE station=p_source_station AND m_date=p_m_date),
            'seabird_sbeeco', p_source_station,
            sbe37_public_station(p_source_station), 'SBE37',
            (SELECT NULLIF(btrim(serial_number_sbe37),'') FROM seabird_sbe37 WHERE station=p_source_station AND m_date=p_m_date),
            p_m_date, p_public_parameter, p_qc_flag, p_rejection_reason, p_rejected_by,
            p_source_query_or_script)
    RETURNING rejection_id INTO v_rejection_id;
    PERFORM sbe37_apply_active_rejections(p_source_station, NULL, p_m_date);
    PERFORM sbe37_create_temperature_dependents(v_rejection_id);
    PERFORM sbe37_create_salinity_dependents(v_rejection_id);
    PERFORM sbe37_create_pressure_dependents(v_rejection_id);
    RETURN v_rejection_id;
END;
$$;

CREATE OR REPLACE FUNCTION reinstate_sbe37_public_parameter(
    p_rejection_id bigint, p_reinstated_by varchar, p_reinstatement_reason varchar)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_parent_rejection_id bigint;
BEGIN
    SELECT parent_rejection_id INTO v_parent_rejection_id
      FROM rejected_observations
     WHERE rejection_id=p_rejection_id AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'active rejection % not found', p_rejection_id; END IF;
    IF v_parent_rejection_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM rejected_observations
         WHERE rejection_id=v_parent_rejection_id AND active
    ) THEN
        RAISE EXCEPTION 'cannot reinstate dependent rejection while parent rejection % remains active', v_parent_rejection_id;
    END IF;
    -- Deactivates the full active descendant subtree (e.g. temperature_water
    -- -> salinity -> SeaFET ph_tempsal), not just direct children, so a
    -- multi-level dependency chain is released together in one call.
    WITH RECURSIVE descendants AS (
        SELECT rejection_id FROM rejected_observations WHERE rejection_id = p_rejection_id
        UNION ALL
        SELECT r.rejection_id FROM rejected_observations r
          JOIN descendants d ON r.parent_rejection_id = d.rejection_id
    )
    UPDATE rejected_observations
       SET active = false, reinstated_at = now(), reinstated_by = p_reinstated_by,
           reinstatement_reason = p_reinstatement_reason
     WHERE rejection_id IN (SELECT rejection_id FROM descendants)
       AND active;
END;
$$;

-- SBE37 temperature is an input to SBE37 salinity and dissolved oxygen
-- (seabird_sbe37_rawfileupdate / production writer convention).  It reaches
-- SeaFET pH only transitively, through the salinity child created below: pH
-- has exactly one provenance path (via salinity), never a direct temperature
-- edge, so reinstatement never has to reconcile two competing parents for the
-- same row.  sbe37_create_salinity_dependents is itself a no-op if the
-- salinity child insert was skipped (e.g. salinity was already independently
-- rejected), which is intentional: that pre-existing rejection already owns
-- any pH child it created.
CREATE OR REPLACE FUNCTION sbe37_create_temperature_dependents(p_parent_rejection_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p rejected_observations%ROWTYPE; v_salinity_child_id bigint;
BEGIN
    SELECT * INTO p FROM rejected_observations WHERE rejection_id=p_parent_rejection_id;
    IF NOT FOUND OR p.source_table <> 'seabird_sbe37'
       OR p.instrument_type <> 'SBE37' OR p.public_parameter <> 'temperature_water' THEN
        RETURN;
    END IF;

    INSERT INTO rejected_observations
      (source_table,source_row_id,public_table,source_station,public_station,instrument_type,
       instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by,
       source_query_or_script,parent_rejection_id)
    SELECT p.source_table,p.source_row_id,p.public_table,p.source_station,p.public_station,p.instrument_type,
           p.instrument_serial,p.m_date,child_parameter,p.qc_flag,
           left('Derived from SBE37 temperature rejection ' || p.rejection_id || ': ' || p.rejection_reason,250),
           p.rejected_by,p.source_query_or_script,p.rejection_id
      FROM unnest(ARRAY['salinity','dissolved_oxygen']) AS child_parameter
    ON CONFLICT DO NOTHING;
    PERFORM sbe37_apply_active_rejections(p.source_station, NULL, p.m_date);

    SELECT rejection_id INTO v_salinity_child_id FROM rejected_observations
     WHERE parent_rejection_id = p.rejection_id AND public_parameter = 'salinity' AND active;
    PERFORM sbe37_create_salinity_dependents(v_salinity_child_id);
END;
$$;

-- SBE37 salinity, together with temperature_water, is an input to SeaFET pH:
-- seafet_ascii/R/seafet_ascii_process_recurring_final.R excludes any row
-- missing either from publication and uses salinity throughout the ionic-
-- strength/Nernst calculation (also seafet_ascii/R/ph_tempsql.R). Called both
-- for a standalone salinity rejection and for the salinity child created by a
-- temperature rejection, so pH always has a single provenance path. A SeaFET
-- child is created only when that SeaFET *private* source observation exists:
-- absence of a pH observation never blocks the originating salinity rejection.
CREATE OR REPLACE FUNCTION sbe37_create_salinity_dependents(p_parent_rejection_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p rejected_observations%ROWTYPE; v_seafet_station varchar;
BEGIN
    SELECT * INTO p FROM rejected_observations WHERE rejection_id=p_parent_rejection_id;
    IF NOT FOUND OR p.source_table <> 'seabird_sbe37'
       OR p.instrument_type <> 'SBE37' OR p.public_parameter <> 'salinity' THEN
        RETURN;
    END IF;

    v_seafet_station := '_' || regexp_replace(p.public_station, '-WQ$', '') || '_SEAFETV1';
    INSERT INTO rejected_observations
      (source_table,source_row_id,public_table,source_station,public_station,instrument_type,
       instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by,
       source_query_or_script,parent_rejection_id)
    SELECT 'seabird_seafetv1', sf.row_id::bigint, 'seabird_seafetv1', sf.station,
           seafetv1_public_station(sf.station), 'SeaFET v1',
           seafetv1_resolve_serial(sf.station,sf.m_date), sf.m_date, 'ph_tempsal',p.qc_flag,
           left('Derived from SBE37 salinity rejection ' || p.rejection_id || ': ' || p.rejection_reason,250),
           p.rejected_by,p.source_query_or_script,p.rejection_id
      FROM seabird_seafetv1 sf
     WHERE sf.station=v_seafet_station AND sf.m_date=p.m_date
    ON CONFLICT DO NOTHING;
    IF FOUND THEN
      PERFORM seafetv1_apply_active_rejections(v_seafet_station,NULL,p.m_date);
    END IF;
END;
$$;

-- SBE37 pressure_water is an input to depth_instrument: the production writer
-- sets depth_instrument = pressure_water in the same row it tags
-- instrument = 'SBE37/ECO' (sbe37_ascii/R/sbe37_ascii_process_recurring_final.R),
-- and sbe37_ascii/docs/instrument_depth_updates.md documents this as an
-- enforced invariant, not a coincidence.
CREATE OR REPLACE FUNCTION sbe37_create_pressure_dependents(p_parent_rejection_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p rejected_observations%ROWTYPE;
BEGIN
    SELECT * INTO p FROM rejected_observations WHERE rejection_id=p_parent_rejection_id;
    IF NOT FOUND OR p.source_table <> 'seabird_sbe37'
       OR p.instrument_type <> 'SBE37' OR p.public_parameter <> 'pressure_water' THEN
        RETURN;
    END IF;

    INSERT INTO rejected_observations
      (source_table,source_row_id,public_table,source_station,public_station,instrument_type,
       instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by,
       source_query_or_script,parent_rejection_id)
    VALUES (p.source_table,p.source_row_id,p.public_table,p.source_station,p.public_station,p.instrument_type,
            p.instrument_serial,p.m_date,'depth_instrument',p.qc_flag,
            left('Derived from SBE37 pressure_water rejection ' || p.rejection_id || ': ' || p.rejection_reason,250),
            p.rejected_by,p.source_query_or_script,p.rejection_id)
    ON CONFLICT DO NOTHING;
    PERFORM sbe37_apply_active_rejections(p.source_station, NULL, p.m_date);
END;
$$;

-- seabird_sbeeco has no serial column.  Its SBE37 identity is the unique
-- mapped private source row at the same timestamp; no session serial context is needed.
CREATE OR REPLACE FUNCTION sbe37_guard_public_parameter_write()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_source_station varchar := sbe37_source_station(NEW.station); r record;
BEGIN
    IF NEW.instrument IS DISTINCT FROM 'SBE37/ECO' THEN RETURN NEW; END IF;
    IF NOT EXISTS (SELECT 1 FROM rejected_observations ro WHERE ro.active
                   AND ro.source_table = 'seabird_sbe37'
                   AND ro.public_table = 'seabird_sbeeco' AND ro.instrument_type = 'SBE37'
                   AND ro.public_station = NEW.station AND ro.m_date = NEW.m_date) THEN RETURN NEW; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM seabird_sbe37 s
         WHERE s.station = v_source_station
           AND s.m_date = NEW.m_date
    ) THEN
        RAISE EXCEPTION 'SBE37 public write has no matching private observation: % / %', v_source_station, NEW.m_date;
    END IF;
    FOR r IN SELECT public_parameter, qc_flag FROM rejected_observations
              WHERE active AND source_table = 'seabird_sbe37'
                AND public_table = 'seabird_sbeeco' AND instrument_type = 'SBE37'
                AND source_station = v_source_station AND m_date = NEW.m_date
    LOOP
        CASE r.public_parameter
          WHEN 'conductivity' THEN NEW.conductivity := NULL; NEW.qc_conductivity := r.qc_flag;
          WHEN 'salinity' THEN NEW.salinity := NULL; NEW.qc_salinity := r.qc_flag;
          WHEN 'temperature_water' THEN NEW.temperature_water := NULL; NEW.qc_temperature_water := r.qc_flag;
          WHEN 'pressure_water' THEN NEW.pressure_water := NULL; NEW.qc_pressure_water := r.qc_flag;
          WHEN 'depth_instrument' THEN NEW.depth_instrument := NULL; NEW.qc_depth_instrument := r.qc_flag;
          WHEN 'oxygen_saturation_perc' THEN NEW.oxygen_saturation_perc := NULL; NEW.qc_oxygen_saturation_perc := r.qc_flag;
          WHEN 'dissolved_oxygen' THEN NEW.dissolved_oxygen := NULL; NEW.qc_dissolved_oxygen := r.qc_flag;
          WHEN 'specific_conductance' THEN NEW.specific_conductance := NULL; NEW.qc_specific_conductance := r.qc_flag;
          ELSE RAISE EXCEPTION 'unsupported active SBE37 public parameter: %', r.public_parameter;
        END CASE;
    END LOOP;
    RETURN NEW;
END;
$$;

-- The private row remains writable and re-applies its matching source-observation suppressions.
CREATE OR REPLACE FUNCTION sbe37_reapply_rejections_after_private_write()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM sbe37_apply_active_rejections(NEW.station, NULL, NEW.m_date);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sbe37_guard_rejected_public_parameters ON seabird_sbeeco;
CREATE TRIGGER sbe37_guard_rejected_public_parameters
    BEFORE INSERT OR UPDATE ON seabird_sbeeco
    FOR EACH ROW EXECUTE FUNCTION sbe37_guard_public_parameter_write();
DROP TRIGGER IF EXISTS sbe37_reapply_rejected_public_parameters ON seabird_sbe37;
CREATE TRIGGER sbe37_reapply_rejected_public_parameters
    AFTER INSERT OR UPDATE ON seabird_sbe37
    FOR EACH ROW EXECUTE FUNCTION sbe37_reapply_rejections_after_private_write();
