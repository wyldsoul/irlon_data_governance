# IRLON Data Governance

Database-side data governance, rejection, and replay-suppression tooling for IRLON data pipelines.

## Current scope

This repository contains a generic public-parameter rejection registry and the
SBE37 public-parameter suppression pilot, its first concrete enforcement module.

The pilot is designed to:

- preserve private/raw SBE37 observations;
- record parameter-level rejection decisions with QC metadata;
- set rejected public parameter values to NULL rather than deleting raw observations;
- prevent recurring, manual, or legacy replay paths from silently repopulating actively rejected public values;
- support explicit, auditable reinstatement.

`rejected_observations.qc_flag` stores the applicable IRLON QARTOD rollup:
`1 = bad`, `2 = suspect`, `3 = good`.

Every active rejection identity includes an instrument serial. If an observation
arrives without its serial, the serial must be resolved from an approved source
or deployment history before a rejection is recorded; otherwise processing must
fail closed rather than create a serial-less identity.

The central `rejected_observations` registry is designed for all governed IRLON
public tables. SBE37, SeaFET v1, SUNA v2, and Nortek Aquadopp have reviewed
non-production modules. ECO and CO2ProCV remain proposed pending production-only
writer and conflict-key validation. Cycle, WQMx, Turner C3, and meteorological
families are not in scope.

## Repository layout

- `sql/` — generic registry plus SBE37 enforcement SQL
- `tests/` — PostgreSQL regression tests
- `docs/` — design, deployment, and writer-integration documentation

## Status

Generic registry + SBE37 pilot only. Not deployed to production.
