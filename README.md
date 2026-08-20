# IRLON Data Governance

Database-side data governance, rejection, and replay-suppression tooling for IRLON data pipelines.

## Current scope

This repository contains a generic public-parameter rejection registry and
instrument-specific public-parameter suppression modules. SBE37 is the first
concrete enforcement pilot; SeaFET v1, SUNA v2, and Nortek Aquadopp have
non-production SQL modules and disposable PostgreSQL 12 validation.

The pilot is designed to:

- preserve private/raw SBE37 observations;
- record parameter-level rejection decisions with QC metadata;
- set rejected public parameter values to NULL rather than deleting raw observations;
- prevent recurring, manual, or legacy replay paths from silently repopulating actively rejected public values;
- support explicit, auditable reinstatement.

`rejected_observations.qc_flag` stores the applicable IRLON QARTOD rollup:
`1 = bad`, `2 = suspect`, `3 = good`.

For an implemented module, rejection identity is the immutable source pair
`(source_table, source_row_id)` plus the public parameter. Source station and
timestamp retain mapping/audit context and locate the source observation during
replay. Where a source table has a unique `(source_station, m_date)` observation
key and one instrument of that type at a station at a time, this is deterministic.
Serial is nullable provenance: it is retained when known but never blocks
suppression.
ECO and CO2ProCV remain outside this simplification because their source rows
are not unique by station and timestamp.

The central `rejected_observations` registry is designed for all governed IRLON
public tables. SBE37, SeaFET v1, SUNA v2, and Nortek Aquadopp have reviewed
non-production modules. ECO and CO2ProCV remain proposed pending production-only
writer and conflict-key validation. Cycle, WQMx, Turner C3, and meteorological
families are not in scope.

## Repository layout

- `sql/` — generic registry plus instrument-specific enforcement SQL
- `tests/` — PostgreSQL regression tests
- `docs/` — design, deployment, and writer-integration documentation

## Status

Not deployed to production. Current readiness is intentionally uneven:

- SBE37: implemented and disposable-tested pilot; writer/clone validation is
  still required.
- SUNA v2: private-first writer compatibility and realistic disposable
  PostgreSQL 12 staging simulation are proven; restored-production-clone,
  permissions, archive, and legacy-write-path validation remain.
- SeaFET v1 and Nortek Aquadopp: disposable-test implementation; both current
  writers are public-first and need separately approved reordering before
  clone validation.
- ECO and CO2ProCV: proposed manual-upload governance adapters only, pending
  immutable source identity / deterministic deduplication validation.
