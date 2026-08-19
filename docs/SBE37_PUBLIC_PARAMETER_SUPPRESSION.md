# SBE37 public-parameter suppression pilot

Implemented as reviewed SQL only: `sql/sbe37_public_parameter_suppression.sql`.
The file creates the generic `rejected_observations` governance registry and
the SBE37-specific enforcement module. It has not been run on production.

`rejected_observations.qc_flag` is deliberately lowercase, unquoted PostgreSQL naming, matching every existing `qc_*` column. It is an `integer`, the live type used by SBE37/public QC columns and by `update_rollup`/`qartod_update_log`. It stores the applicable IRLON QARTOD rollup: `1 = bad`, `2 = suspect`, `3 = good`; the SBE37 enforcement module writes that stored flag to the paired public `qc_<parameter>` column while NULLing the public value.

The generic registry identity is `(source_table, public_table, source_station,
public_station, instrument_type, instrument_serial, m_date, public_parameter)`.
`instrument_serial` is required because every active IRLON instrument has a
serial identity. If a source observation temporarily omits its serial, it must
be resolved from an approved source or deployment history, or fail closed; it
must not create a serial-less rejection identity. A range was intentionally not
retained. The SBE37 module supplies
`instrument_type = 'SBE37'` and maps its real source column
`serial_number_sbe37` to the generic registry column `instrument_serial`.

Active uniqueness uses one PostgreSQL 12-compatible partial unique index over
the complete identity, including `instrument_serial`, for active records. A
reinstated record remains in history without blocking a later active decision.

`public_parameter` is generic text. The production `parameter` table defines
sensor/QC thresholds and `loggernet2db` maps ingest fields, but neither is an
authoritative `public_table + public_parameter` catalog. Each enforcement module
therefore validates its own supported parameters; SBE37 uses its explicit fixed
CASE rather than dynamic SQL. A reusable catalog can be introduced later if it
becomes authoritative across instruments.

The confirmed mapping is private `_IRL-<station>_SBE37` / serial / hour to public `IRL-<station>-WQ` / hour. Supported public parameters are `conductivity`, `salinity`, `temperature_water`, `pressure_water`, `depth_instrument`, `oxygen_saturation_perc`, `dissolved_oxygen`, and `specific_conductance`.

`reject_sbe37_public_parameter(...)` is the rejection API. It verifies the private identity, inserts the decision, and NULLs exactly the requested public parameter in one transaction. `reinstate_sbe37_public_parameter(...)` only deactivates and audits the decision; it never reconstructs a historical value.

The database trigger on `seabird_sbe37` preserves raw/private writes and reapplies matching public NULLs after private replay. Since `seabird_sbeeco` has no serial column, its guard trigger refuses an SBE37/ECO public write at a rejected timestamp unless its transaction-local identity both maps from the supplied private station to `NEW.station` and identifies an existing private row at the same serial/timestamp. This is necessary to avoid accidentally suppressing or authorizing a different serial at the same public `(station, m_date)`. Therefore the eventual writers must upsert private first, then use a single-statement identity-context/public-upsert form. Their working tree is currently user-modified, so this change is not applied here. The legacy `Q_manualuploads_sbe37.sql` writes the private table only and is covered by the private trigger.

For practical per-run reporting, a writer calls `sbe37_count_active_rejections(private_station, serial, m_date)` immediately before each public upsert and sums the results. That produces `N rejected public parameter values suppressed` without duplicating the suppression decision; DB triggers remain the enforcement boundary.

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

The disposable-container test covers normal writes, one-parameter rejection, private-data preservation, station/serial/timestamp identity bypasses, autocommit statement-local identity isolation, single-statement public upserts, private-only legacy replay, different-serial identity, reinstatement, and rollback atomicity. It does not benchmark production volume or validate live writer integration.

## Production deployment sequence (proposed; not executed)

1. Obtain explicit production approval and schedule a maintenance window. The registry uses the established IRLON QARTOD rollup (`1 = bad`, `2 = suspect`, `3 = good`). Do not create the registry from archive history.
2. On a clean branch, apply and review the two-writer integration in `SBE37_PUBLIC_PARAMETER_SUPPRESSION_WRITER_INTEGRATION.md`. It must preserve and upsert `serial_number_sbe37`, upsert private before each associated public row, establish per-row public identity in the same statement as the public upsert, and report the summed count. Test it against a staging/restored production clone.
3. On production, first capture the current DDL for `seabird_sbe37`, `seabird_sbeeco`, their archive triggers/functions, and the SBE37 writer revision. Confirm the active staging backlog is understood. Stop only the SBE37 recurring/manual writers for the window; do not modify unrelated cron jobs.
4. In one reviewed transaction, with an explicit lock timeout, execute `SET LOCAL search_path = public;` followed by `sql/sbe37_public_parameter_suppression.sql`, then verify the new table, index, functions, and two triggers. Commit only after those checks succeed; otherwise roll back.
5. Deploy the reviewed writer revision before resuming any SBE37 writer. Run one normal, non-rejected staging-equivalent upload and verify no unexpected archive/public updates. Then create a single approved test rejection through `reject_sbe37_public_parameter(...)`, replay its source, and verify only the rejected public parameter remains NULL.
6. Resume the SBE37 writers and monitor the new suppression count, trigger errors, archive volume, and raw/private serial population. Do not register historical data as rejected without a separately approved decision.
7. If a pre-go-live problem occurs before any real rejection is entered, stop SBE37 writers and roll back the migration transaction. After real decisions exist, do not drop the registry as a casual rollback: disable the new triggers only under a separately approved incident plan, preserving the audit registry and public NULLs.
