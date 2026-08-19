-- SUNA v2 module. Requires rejected_observations. Private rows use _<site>_SUNA
-- and public rows use <site>-WQ in the same seabird_sunav2 table.
CREATE FUNCTION sunav2_public_station(p varchar) RETURNS varchar LANGUAGE sql IMMUTABLE STRICT AS $$
 SELECT CASE WHEN p ~ '^_.+_SUNA$' THEN regexp_replace(p,'^_(.+)_SUNA$',E'\\1-WQ') END $$;
CREATE FUNCTION sunav2_source_station(p varchar) RETURNS varchar LANGUAGE sql IMMUTABLE STRICT AS $$
 SELECT CASE WHEN p ~ '^.+-WQ$' THEN '_'||regexp_replace(p,'-WQ$','')||'_SUNA' END $$;
CREATE FUNCTION sunav2_resolve_serial(p_station varchar,p_m_date timestamptz)
RETURNS varchar LANGUAGE sql STABLE AS $$
 SELECT NULLIF(btrim(serial_number_suna),'') FROM seabird_sunav2 WHERE station=p_station AND m_date=p_m_date $$;
CREATE FUNCTION sunav2_count_active_rejections(p_station varchar,p_serial varchar,p_m_date timestamptz)
RETURNS integer LANGUAGE sql STABLE AS $$
 SELECT count(*)::integer FROM rejected_observations
 WHERE active AND source_table='seabird_sunav2' AND public_table='seabird_sunav2'
   AND instrument_type='SUNA v2' AND source_station=p_station
   AND instrument_serial=p_serial AND m_date=p_m_date $$;
CREATE FUNCTION sunav2_apply_active_rejections(p_station varchar,p_serial varchar,p_m_date timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
 FOR r IN SELECT * FROM rejected_observations WHERE active AND source_table='seabird_sunav2'
   AND public_table='seabird_sunav2' AND instrument_type='SUNA v2' AND source_station=p_station
   AND instrument_serial=p_serial AND m_date=p_m_date LOOP
  UPDATE seabird_sunav2 SET nitrate_um=CASE WHEN r.public_parameter='nitrate_um' THEN NULL ELSE nitrate_um END,
    qc_nitrate_um=CASE WHEN r.public_parameter='nitrate_um' THEN r.qc_flag ELSE qc_nitrate_um END,
    nitrate_mgl=CASE WHEN r.public_parameter='nitrate_mgl' THEN NULL ELSE nitrate_mgl END,
    qc_nitrate_mgl=CASE WHEN r.public_parameter='nitrate_mgl' THEN r.qc_flag ELSE qc_nitrate_mgl END
  WHERE station=r.public_station AND m_date=r.m_date;
 END LOOP;
END $$;
CREATE FUNCTION reject_sunav2_public_parameter(p_source_station varchar,p_serial_number_suna varchar,p_m_date timestamptz,p_public_parameter varchar,p_qc_flag integer,p_rejection_reason varchar,p_rejected_by varchar DEFAULT current_user,p_source_query_or_script text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_serial varchar; v_id bigint; v_public varchar;
BEGIN
 v_public:=sunav2_public_station(p_source_station);
 IF v_public IS NULL OR p_public_parameter NOT IN ('nitrate_um','nitrate_mgl') THEN RAISE EXCEPTION 'unsupported SUNA v2 identity or public parameter'; END IF;
 v_serial:=sunav2_resolve_serial(p_source_station,p_m_date);
 IF v_serial IS NULL OR NULLIF(btrim(p_serial_number_suna),'') IS DISTINCT FROM v_serial THEN RAISE EXCEPTION 'SUNA v2 source serial is missing or does not match source identity'; END IF;
 INSERT INTO rejected_observations(source_table,public_table,source_station,public_station,instrument_type,instrument_serial,m_date,public_parameter,qc_flag,rejection_reason,rejected_by,source_query_or_script)
 VALUES ('seabird_sunav2','seabird_sunav2',p_source_station,v_public,'SUNA v2',v_serial,p_m_date,p_public_parameter,p_qc_flag,p_rejection_reason,p_rejected_by,p_source_query_or_script) RETURNING rejection_id INTO v_id;
 PERFORM sunav2_apply_active_rejections(p_source_station,v_serial,p_m_date); RETURN v_id;
END $$;
CREATE FUNCTION reinstate_sunav2_public_parameter(p_source_station varchar,p_serial_number_suna varchar,p_m_date timestamptz,p_public_parameter varchar,p_reinstated_by varchar DEFAULT current_user,p_reinstatement_reason varchar DEFAULT 'reinstated')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 UPDATE rejected_observations SET active=false,reinstated_at=now(),reinstated_by=p_reinstated_by,reinstatement_reason=p_reinstatement_reason
 WHERE active AND source_table='seabird_sunav2' AND public_table='seabird_sunav2' AND instrument_type='SUNA v2' AND source_station=p_source_station AND instrument_serial=p_serial_number_suna AND m_date=p_m_date AND public_parameter=p_public_parameter;
 IF NOT FOUND THEN RAISE EXCEPTION 'active SUNA v2 rejection not found'; END IF;
END $$;
CREATE FUNCTION sunav2_guard_public_parameter_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_source varchar;v_serial varchar;r record;
BEGIN
 IF NEW.station !~ '^.+-WQ$' THEN RETURN NEW; END IF; v_source:=sunav2_source_station(NEW.station);v_serial:=sunav2_resolve_serial(v_source,NEW.m_date);
 IF v_serial IS NULL THEN
  IF EXISTS(SELECT 1 FROM rejected_observations WHERE active AND source_table='seabird_sunav2' AND public_table='seabird_sunav2' AND instrument_type='SUNA v2' AND source_station=v_source AND public_station=NEW.station AND m_date=NEW.m_date) THEN RAISE EXCEPTION 'cannot safely write SUNA v2 public row: source serial unresolved'; END IF; RETURN NEW;
 END IF;
 FOR r IN SELECT * FROM rejected_observations WHERE active AND source_table='seabird_sunav2' AND public_table='seabird_sunav2' AND instrument_type='SUNA v2' AND source_station=v_source AND instrument_serial=v_serial AND m_date=NEW.m_date LOOP
  IF r.public_parameter='nitrate_um' THEN NEW.nitrate_um:=NULL;NEW.qc_nitrate_um:=r.qc_flag; ELSIF r.public_parameter='nitrate_mgl' THEN NEW.nitrate_mgl:=NULL;NEW.qc_nitrate_mgl:=r.qc_flag; END IF;
 END LOOP; RETURN NEW;
END $$;
CREATE FUNCTION sunav2_reapply_rejections_after_private_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_serial varchar;
BEGIN
 IF NEW.station !~ '^_.+_SUNA$' THEN RETURN NEW; END IF; v_serial:=sunav2_resolve_serial(NEW.station,NEW.m_date); IF v_serial IS NULL THEN RETURN NEW; END IF;
 IF EXISTS(SELECT 1 FROM rejected_observations WHERE active AND source_table='seabird_sunav2' AND public_table='seabird_sunav2' AND instrument_type='SUNA v2' AND source_station=NEW.station AND instrument_serial=v_serial AND m_date=NEW.m_date) THEN PERFORM sunav2_apply_active_rejections(NEW.station,v_serial,NEW.m_date); END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sunav2_guard_rejected_public_parameters BEFORE INSERT OR UPDATE ON seabird_sunav2 FOR EACH ROW EXECUTE FUNCTION sunav2_guard_public_parameter_write();
CREATE TRIGGER sunav2_reapply_rejected_public_parameters AFTER INSERT OR UPDATE ON seabird_sunav2 FOR EACH ROW EXECUTE FUNCTION sunav2_reapply_rejections_after_private_write();
