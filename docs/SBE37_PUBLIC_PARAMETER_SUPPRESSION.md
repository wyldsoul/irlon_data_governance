# SBE37 public-parameter suppression pilot

Implemented as reviewed SQL only: `sql/sbe37_public_parameter_suppression.sql`.
That file is the reapplicable SBE37-specific enforcement module; the generic
`rejected_observations` registry is installed separately. Neither has been run
on production.

For deployment, the generic first-install DDL is isolated in
`sql/rejected_observations_schema.sql`. The SBE37 and SeaFET module files use
`CREATE OR REPLACE FUNCTION` and explicitly recreate only their own triggers,
so `sql/deploy_sbe37_seafetv1_upgrade.sql` can safely reapply them to an
already-installed compatible registry without changing rejection history or
identity values. `sql/deploy_sbe37_seafetv1_clean.sql` is the separate clean
installation entry point.

`rejected_observations.qc_flag` is deliberately lowercase, unquoted PostgreSQL naming, matching every existing `qc_*` column. It is an `integer`, the live type used by SBE37/public QC columns and by `update_rollup`/`qartod_update_log`. It stores the applicable IRLON QARTOD rollup: `1 = bad`, `2 = suspect`, `3 = good`; the SBE37 enforcement module writes that stored flag to the paired public `qc_<parameter>` column while NULLing the public value.

The implemented registry identity is `(source_table, source_row_id,
public_parameter)`. The source/public stations, instrument type, and timestamp
remain mapping and audit context. The unique SBE37 private `(station,m_date)`
source row is sufficient to locate that immutable row because only one SBE37 is
deployed at a source station at a time. `instrument_serial` is nullable
provenance when known, not a rejection-identity requirement.

Active uniqueness uses one PostgreSQL 12-compatible partial unique index over
the source-observation identity for active records. A
reinstated record remains in history without blocking a later active decision.

`public_parameter` is generic text. The production `parameter` table defines
sensor/QC thresholds and `loggernet2db` maps ingest fields, but neither is an
authoritative `public_table + public_parameter` catalog. Each enforcement module
therefore validates its own supported parameters; SBE37 uses its explicit fixed
CASE rather than dynamic SQL. A reusable catalog can be introduced later if it
becomes authoritative across instruments.

The confirmed mapping is private `_IRL-<station>_SBE37` / hour to public `IRL-<station>-WQ` / hour. Supported public parameters are `conductivity`, `salinity`, `temperature_water`, `pressure_water`, `depth_instrument`, `oxygen_saturation_perc`, `dissolved_oxygen`, and `specific_conductance`.

`reject_sbe37_public_parameter(...)` uses that exact fixed allowlist and fails
before creating a registry row for any unsupported or misspelled parameter.
The public guard and private-replay apply function also fail closed if a direct
manual registry insertion somehow creates an unsupported active SBE37 parameter;
they never silently treat it as a no-op.

`reject_sbe37_public_parameter(...)` is the rejection API. It verifies the private identity, stores its `row_id`, inserts the decision, and NULLs the requested public parameter in one transaction.

The confirmed calculation dependency graph, evidenced against the production writers rather than inferred from scientific convention:

- `temperature_water` is an input to `salinity` and `dissolved_oxygen` (production writer convention). A `temperature_water` rejection creates linked child decisions for both, with the same QARTOD flag.
- `salinity`, together with `temperature_water`, is a required input to SeaFET `ph_tempsal`: `seafet_ascii/R/seafet_ascii_process_recurring_final.R` excludes any row missing either from publication, and `salinity` is used throughout the ionic-strength/Nernst pH calculation. A `salinity` rejection — whether standalone or the child created by a `temperature_water` rejection — creates a linked SeaFET `ph_tempsal` child when a matching private SeaFET source row exists for the mapped public station/timestamp. Missing SeaFET input never blocks the SBE37/salinity decision.
- `ph_tempsal` therefore has a single provenance path, transitively through `salinity` (`temperature_water -> salinity -> ph_tempsal`), never a direct edge from `temperature_water`. This avoids two independent code paths ever competing to create the same `ph_tempsal` registry row.
- `pressure_water` is an input to `depth_instrument`: the production writer sets `depth_instrument = pressure_water` in the same row it tags `instrument = 'SBE37/ECO'` (`sbe37_ascii/R/sbe37_ascii_process_recurring_final.R`), documented as an enforced invariant in `sbe37_ascii/docs/instrument_depth_updates.md`. A `pressure_water` rejection creates a linked `depth_instrument` child with the same flag.
- `oxygen_saturation_perc` is **not** a dependent of anything in this module's scope. The only production code that derives it (`oxygen_saturation_perc = oxygen_saturation_perc_raw * 100`) explicitly excludes `instrument != 'SBE37/ECO'` rows, and this module's guard trigger only governs rows tagged `instrument = 'SBE37/ECO'` — the two code paths never overlap.
- `conductivity`, `dissolved_oxygen`, and `specific_conductance` have no evidenced dependents.

**Known edge case — salinity rejected first, temperature rejected second (SAFE BUT PROVENANCE-LIMITED):** if `salinity` is rejected standalone first (creating its own `ph_tempsal` child), and `temperature_water` is rejected afterward for the same observation, temperature's attempt to insert its own `salinity` child silently no-ops against the source-observation unique index (`ON CONFLICT DO NOTHING`) rather than adopting the pre-existing salinity rejection as its child. Verified against a restored clone on 2026-08-20: the standalone `salinity` rejection and its `ph_tempsal` child remain completely unaffected — still active, still correctly suppressed, still independently reinstatable — and `temperature_water` still creates its own `dissolved_oxygen` child normally. Reinstating `temperature_water` afterward releases only its own subtree (itself and `dissolved_oxygen`); the earlier, independent `salinity`/`ph_tempsal` rejection is untouched and remains active, exactly as it should. No suppressed value is ever exposed. The only imperfection is provenance: `temperature_water`'s registry row carries no link acknowledging that `salinity` was already independently governed for the same observation. This is accepted as-is rather than fixed, since fixing it (e.g. auto-adopting a pre-existing rejection as a child) risks silently changing an existing rejection's lineage — the ambiguity this design deliberately avoids elsewhere.

`reinstate_sbe37_public_parameter(...)` deactivates the target rejection and its full active descendant subtree — not just direct children — so a multi-level chain (e.g. `temperature_water -> salinity -> ph_tempsal`) is released together in one call. It never reconstructs a historical value.

A dependent row cannot be independently reinstated while its
`parent_rejection_id` still names an active parent: the function raises rather
than silently changing the child. This check only needs to examine the
immediate parent, not the full ancestor chain, because a row can never be
active while its own direct parent is active — an invariant maintained by the
full-subtree cascade on reinstatement. The topmost parent in a chain is the
only lifecycle decision and may deactivate itself and every active descendant
together. After reinstatement, a normal writer replay restores measurements;
QC restoration is deliberately a separate QARTOD reevaluation concern.

The database trigger on `seabird_sbe37` preserves raw/private writes and reapplies matching public NULLs after private replay. Since `seabird_sbeeco` has no serial column, its guard derives the mapped private station and verifies the unique source row at the same timestamp. Blank source serials remain raw provenance and do not block suppression. The legacy `Q_manualuploads_sbe37.sql` writes the private table only and is covered by the private trigger.

For practical per-run reporting, a writer calls `sbe37_count_active_rejections(private_station, serial, m_date)` immediately before each public upsert and sums the results. The retained serial argument is compatibility-only; reporting matches source station and timestamp.

See [the generic architecture](ARCHITECTURE.md). No other instrument has an
implemented trigger or enforcement module.

Run the disposable PostgreSQL test with:

```sh
docker run --rm -v "$PWD":/workspace -w /workspace --entrypoint sh postgres:12 -c \
  "su postgres -c 'initdb -D /tmp/irlon-suppression-pg && \
   pg_ctl -D /tmp/irlon-suppression-pg -o \"-k /tmp -p 55432\" -w start && \
   psql -h /tmp -p 55432 -U postgres -d postgres -f tests/test_sbe37_public_parameter_suppression.sql; \
   test_status=\$?; pg_ctl -D /tmp/irlon-suppression-pg -m fast -w stop; exit \$test_status'"
```

The disposable-container test covers normal writes, one-parameter rejection, private-data preservation, source-row identity, blank serial provenance, station/serial/timestamp identity bypasses, single-statement public upserts, private-only legacy replay, reinstatement, rollback atomicity, the SBE37-temperature → SBE37-salinity/DO → matching-SeaFET-pH transitive dependency chain, a standalone `salinity` → SeaFET-pH rejection, and a `pressure_water` → `depth_instrument` rejection. It does not benchmark production volume or validate live writer integration.

## Production deployment sequence (proposed; not executed)

1. Obtain explicit production approval and schedule a maintenance window. The registry uses the established IRLON QARTOD rollup (`1 = bad`, `2 = suspect`, `3 = good`). Do not create the registry from archive history.
   The temperature-to-SeaFET and salinity-to-SeaFET dependencies require the
   reviewed SeaFET module to be installed in the same approved deployment
   sequence before SBE37 temperature or salinity rejections are entered.
2. On a clean branch, apply and review the two-writer integration in `SBE37_PUBLIC_PARAMETER_SUPPRESSION_WRITER_INTEGRATION.md`. It must preserve and upsert `serial_number_sbe37`, upsert private before each associated public row, establish per-row public identity in the same statement as the public upsert, and report the summed count. Test it against a staging/restored production clone.
3. On production, first capture the current DDL for `seabird_sbe37`, `seabird_sbeeco`, their archive triggers/functions, and the SBE37 writer revision. Confirm the active staging backlog is understood. Stop only the SBE37 recurring/manual writers for the window; do not modify unrelated cron jobs.
4. In one reviewed transaction, with an explicit lock timeout, execute `SET LOCAL search_path = public;` followed by `sql/sbe37_public_parameter_suppression.sql`, then verify the new table, index, functions, and two triggers. Commit only after those checks succeed; otherwise roll back.
5. Deploy the reviewed writer revision before resuming any SBE37 writer. Run one normal, non-rejected staging-equivalent upload and verify no unexpected archive/public updates. Then create a single approved test rejection through `reject_sbe37_public_parameter(...)`, replay its source, and verify only the rejected public parameter remains NULL.
6. Resume the SBE37 writers and monitor the new suppression count, trigger errors, archive volume, and raw/private serial population. Do not register historical data as rejected without a separately approved decision.
7. If a pre-go-live problem occurs before any real rejection is entered, stop SBE37 writers and roll back the migration transaction. After real decisions exist, do not drop the registry as a casual rollback: disable the new triggers only under a separately approved incident plan, preserving the audit registry and public NULLs.
