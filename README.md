# IRLON Data Governance

Database-side data governance, rejection, and replay-suppression tooling for IRLON data pipelines.

## Current scope

This repository currently contains the SBE37 public-parameter suppression pilot.

The pilot is designed to:

- preserve private/raw SBE37 observations;
- record parameter-level rejection decisions with QC metadata;
- set rejected public parameter values to NULL rather than deleting raw observations;
- prevent recurring, manual, or legacy replay paths from silently repopulating actively rejected public values;
- support explicit, auditable reinstatement.

## Repository layout

- `sql/` — database-side suppression SQL
- `tests/` — PostgreSQL regression tests
- `docs/` — design, deployment, and writer-integration documentation

## Status

Pilot only. Not deployed to production.
