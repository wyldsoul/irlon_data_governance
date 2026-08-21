\set ON_ERROR_STOP on
-- First installation only.  Creates the generic registry, then installs the
-- SeaFET and SBE37 modules in one transaction.  Run with psql -f from any
-- directory; \ir resolves the included files relative to this file.
BEGIN;
SET LOCAL search_path = public;
\ir rejected_observations_schema.sql
\ir seafetv1/public_parameter_suppression.sql
\ir sbe37_public_parameter_suppression.sql
COMMIT;
