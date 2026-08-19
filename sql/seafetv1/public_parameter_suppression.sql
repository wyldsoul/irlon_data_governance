-- SeaFET v1 module.  Requires rejected_observations to exist first.
-- The physical table is shared: underscore-prefixed stations are private/raw
-- SeaFET rows and the corresponding -WQ station is the public row.

CREATE FUNCTION seafetv1_public_station(p_source_station varchar)
RETURNS varchar LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE WHEN p_source_station ~ '^_.+_SEAFETV1$'
              THEN regexp_replace(p_source_station, '^_(.+)_SEAFETV1$', E'\\1-WQ') END
$$;

CREATE FUNCTION seafetv1_source_station(p_public_station varchar)
RETURNS varchar LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE WHEN p_public_station ~ '^.+-WQ$'
              THEN '_' || regexp_replace(p_public_station, '-WQ$', '') || '_SEAFETV1' END
$$;

-- Exact serial wins.  The only observed serial gap was 24 consecutive hourly
-- rows at one station; resolve only when the nearest known serial on both sides
-- is within 24 hours and agrees.  This cannot cross a serial transition.
CREATE FUNCTION seafetv1_resolve_serial(p_source_station varchar, p_m_date timestamptz)
RETURNS varchar LANGUAGE plpgsql STABLE AS $$
DECLARE v_exact varchar; v_prior varchar; v_next varchar;
        v_prior_date timestamptz; v_next_date timestamptz;
BEGIN
  SELECT NULLIF(btrim(serial_number_seafet), '') INTO v_exact
    FROM seabird_seafetv1 WHERE station=p_source_station AND m_date=p_m_date;
  IF v_exact IS NOT NULL THEN RETURN v_exact; END IF;
  SELECT m_date, NULLIF(btrim(serial_number_seafet), '') INTO v_prior_date, v_prior
    FROM seabird_seafetv1
   WHERE station=p_source_station AND m_date < p_m_date
     AND NULLIF(btrim(serial_number_seafet), '') IS NOT NULL
   ORDER BY m_date DESC LIMIT 1;
  SELECT m_date, NULLIF(btrim(serial_number_seafet), '') INTO v_next_date, v_next
    FROM seabird_seafetv1
   WHERE station=p_source_station AND m_date > p_m_date
     AND NULLIF(btrim(serial_number_seafet), '') IS NOT NULL
   ORDER BY m_date LIMIT 1;
  IF v_prior IS NOT NULL AND v_next IS NOT NULL AND v_prior=v_next
     AND p_m_date-v_prior_date <= interval '24 hours'
     AND v_next_date-p_m_date <= interval '24 hours' THEN
    RETURN v_prior;
  END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION reject_seafetv1_public_parameter(
  p_source_station varchar, p_serial_number_seafet varchar, p_m_date timestamptz,
  p_public_parameter varchar, p_qc_flag integer, p_rejection_reason varchar,
  p_rejected_by varchar DEFAULT current_user, p_source_query_or_script text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_serial varchar; v_rejection_id bigint; v_public_station varchar;
BEGIN
  v_public_station := seafetv1_public_station(p_source_station);
  IF v_public_station IS NULL OR p_public_parameter <> 'ph_tempsal' THEN
    RAISE EXCEPTION 'unsupported SeaFET v1 identity or public parameter';
  END IF;
  v_serial := seafetv1_resolve_serial(p_source_station, p_m_date);
  IF v_serial IS NULL OR NULLIF(btrim(p_serial_number_seafet),'') IS DISTINCT FROM v_serial THEN
    RAISE EXCEPTION 'SeaFET v1 source serial is missing, ambiguous, or does not match source identity';
  END IF;
  INSERT INTO rejected_observations
    (source_table,public_table,source_station,public_station,instrument_type,
     instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by,source_query_or_script)
  VALUES ('seabird_seafetv1','seabird_seafetv1',p_source_station,v_public_station,'SeaFET v1',
          v_serial,p_m_date,p_public_parameter,p_qc_flag,p_rejection_reason,p_rejected_by,p_source_query_or_script)
  RETURNING rejection_id INTO v_rejection_id;
  PERFORM seafetv1_apply_active_rejections(p_source_station,v_serial,p_m_date);
  RETURN v_rejection_id;
END;
$$;

CREATE FUNCTION seafetv1_apply_active_rejections(p_source_station varchar, p_serial varchar, p_m_date timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE seabird_seafetv1 AS p
     SET ph_tempsal = NULL, qc_ph_tempsal = r.qc_flag
    FROM rejected_observations AS r
   WHERE r.active AND r.source_table='seabird_seafetv1' AND r.public_table='seabird_seafetv1'
     AND r.instrument_type='SeaFET v1' AND r.source_station=p_source_station
     AND r.instrument_serial=p_serial AND r.m_date=p_m_date AND r.public_parameter='ph_tempsal'
     AND p.station=r.public_station AND p.m_date=r.m_date;
END;
$$;

CREATE FUNCTION reinstate_seafetv1_public_parameter(
  p_source_station varchar, p_serial_number_seafet varchar, p_m_date timestamptz,
  p_public_parameter varchar, p_reinstated_by varchar DEFAULT current_user,
  p_reinstatement_reason varchar DEFAULT 'reinstated')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE rejected_observations SET active=false, reinstated_at=now(),
         reinstated_by=p_reinstated_by, reinstatement_reason=p_reinstatement_reason
   WHERE active AND source_table='seabird_seafetv1' AND public_table='seabird_seafetv1'
     AND instrument_type='SeaFET v1' AND source_station=p_source_station
     AND instrument_serial=p_serial_number_seafet AND m_date=p_m_date
     AND public_parameter=p_public_parameter;
  IF NOT FOUND THEN RAISE EXCEPTION 'active SeaFET v1 rejection not found'; END IF;
END;
$$;

CREATE FUNCTION seafetv1_guard_public_parameter_write()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_source_station varchar; v_serial varchar; v_qc integer;
BEGIN
  IF NEW.station !~ '^.+-WQ$' THEN RETURN NEW; END IF;
  v_source_station := seafetv1_source_station(NEW.station);
  v_serial := seafetv1_resolve_serial(v_source_station, NEW.m_date);
  IF v_serial IS NULL THEN
    IF EXISTS (SELECT 1 FROM rejected_observations WHERE active
      AND source_table='seabird_seafetv1' AND public_table='seabird_seafetv1'
      AND instrument_type='SeaFET v1' AND source_station=v_source_station
      AND public_station=NEW.station AND m_date=NEW.m_date AND public_parameter='ph_tempsal') THEN
      RAISE EXCEPTION 'cannot safely write SeaFET v1 public row: source serial unresolved';
    END IF;
    RETURN NEW;
  END IF;
  SELECT qc_flag INTO v_qc FROM rejected_observations WHERE active
    AND source_table='seabird_seafetv1' AND public_table='seabird_seafetv1'
    AND instrument_type='SeaFET v1' AND source_station=v_source_station AND instrument_serial=v_serial
    AND m_date=NEW.m_date AND public_parameter='ph_tempsal';
  IF FOUND THEN NEW.ph_tempsal := NULL; NEW.qc_ph_tempsal := v_qc; END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION seafetv1_reapply_rejections_after_private_write()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_serial varchar;
BEGIN
  IF NEW.station !~ '^_.+_SEAFETV1$' THEN RETURN NEW; END IF;
  v_serial := seafetv1_resolve_serial(NEW.station, NEW.m_date);
  IF v_serial IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM rejected_observations WHERE active AND source_table='seabird_seafetv1'
       AND public_table='seabird_seafetv1' AND instrument_type='SeaFET v1'
       AND source_station=NEW.station AND instrument_serial=v_serial AND m_date=NEW.m_date) THEN
    PERFORM seafetv1_apply_active_rejections(NEW.station,v_serial,NEW.m_date);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER seafetv1_guard_rejected_public_parameters
BEFORE INSERT OR UPDATE ON seabird_seafetv1 FOR EACH ROW EXECUTE FUNCTION seafetv1_guard_public_parameter_write();
CREATE TRIGGER seafetv1_reapply_rejected_public_parameters
AFTER INSERT OR UPDATE ON seabird_seafetv1 FOR EACH ROW EXECUTE FUNCTION seafetv1_reapply_rejections_after_private_write();
