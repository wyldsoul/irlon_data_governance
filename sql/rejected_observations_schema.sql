-- Generic rejected-observation registry. First installation only: this file
-- deliberately creates the table and its identity indexes, and must not be
-- used to reapply SBE37/SeaFET module definitions to an existing registry.
-- Execute with search_path set to the intended schema (public in deployment).

CREATE TABLE rejected_observations (
    rejection_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_table varchar(100) NOT NULL,
    public_table varchar(100) NOT NULL,
    source_station varchar NOT NULL,
    public_station varchar NOT NULL,
    instrument_type varchar(50) NOT NULL,
    -- Immutable identity of the source observation within source_table.  It is
    -- populated by every implemented module; NULL is retained only for legacy
    -- or future adapters that have not yet established a source-row mapping.
    source_row_id bigint,
    instrument_serial varchar,
    m_date timestamp with time zone NOT NULL,
    public_parameter varchar(100) NOT NULL,
    -- IRLON QARTOD rollup: 1 = bad, 2 = suspect, 3 = good.
    qc_flag integer NOT NULL CHECK (qc_flag IN (1, 2, 3)),
    rejection_reason varchar(250) NOT NULL,
    rejected_at timestamp with time zone NOT NULL DEFAULT now(),
    rejected_by varchar(50) NOT NULL DEFAULT current_user,
    source_query_or_script text,
    -- A derived rejection is linked to the source-parameter rejection that
    -- caused it.  Independently rejected parameters have NULL here.
    parent_rejection_id bigint REFERENCES rejected_observations(rejection_id),
    active boolean NOT NULL DEFAULT true,
    reinstated_at timestamp with time zone,
    reinstated_by varchar(50),
    reinstatement_reason varchar(250),
    CHECK ((active AND reinstated_at IS NULL AND reinstated_by IS NULL AND reinstatement_reason IS NULL)
        OR (NOT active AND reinstated_at IS NOT NULL AND reinstated_by IS NOT NULL AND reinstatement_reason IS NOT NULL))
);

-- For a source table with a unique (station,m_date) observation key and one
-- instrument of this type per station, serial is provenance rather than identity.
CREATE UNIQUE INDEX rejected_observations_active_source_row_parameter_key
    ON rejected_observations
       (source_table, source_row_id, public_parameter)
    WHERE active AND source_row_id IS NOT NULL;

-- Transitional fallback for a future/legacy source that cannot yet provide a
-- row_id.  Implemented modules must use the source-row key above.
CREATE UNIQUE INDEX rejected_observations_active_legacy_parameter_key
    ON rejected_observations
       (source_table, public_table, source_station, public_station,
        instrument_type, m_date, public_parameter)
    WHERE active AND source_row_id IS NULL;
