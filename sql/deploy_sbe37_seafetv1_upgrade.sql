\set ON_ERROR_STOP on
-- Reapply only replaceable SBE37/SeaFET routines and their triggers.  This
-- file never creates, drops, truncates, or alters rejected_observations.
-- It requires the compatible registry already to exist.
BEGIN;
SET LOCAL search_path = public;
\ir seafetv1/public_parameter_suppression.sql
\ir sbe37_public_parameter_suppression.sql
COMMIT;
