# SUNA v2 restored-production-clone validation

This is the next validation boundary after
`tests/sunav2/test_realistic_staging.sql`. It is a runbook for a disposable,
access-controlled restored-production clone. It is not authorization to change
production, the scheduled writer, cron, or any `/home/irlon/...` file.

## Preconditions and evidence capture

1. The database owner creates a clone from an approved production backup and
   records the backup timestamp, PostgreSQL version, schema name, and the
   clone-only connection target. Do not point the writer at production.
2. Before adding governance SQL, capture the clone DDL for
   `seabird_sunav2`, `seabird_sunav2_archive`, `archive_trigger_sunav2`, its
   trigger function, related station constraints, and every existing SUNA
   trigger/function. Record enabled/disabled trigger state and owner/role
   permissions.
3. Capture the actual `application_name` condition used by the cloned archive
   trigger and the value set by
   `suna_ascii_tscorrection_recurring_final.R`. Treat a difference between
   `suna_ascii_process_recurring_final.R` and
   `suna_ascii_tscorrection_recurring_final.R` as an unresolved finding; do
   not rename either side during this exercise.
4. Choose a clone-only SUNA fixture with one exact private source row, serial,
   timestamp, mapped `-WQ` row, and at least one unrejected parameter. Record
   only the identifiers needed to reproduce the test.

## Clone procedure

1. In one clone-only transaction/install session, load the generic registry
   and `sql/sunav2/public_parameter_suppression.sql`; capture the resulting
   DDL and trigger list. Do not install them in production.
2. Run the current recurring writer unchanged against the clone using a
   clone-only connection configuration supplied by the owner. Confirm the
   private `_SITE_SUNA` upsert commits before the public `SITE-WQ` upsert and
   preserves `serial_number_suna` on insert and conflict update.
3. Record baseline row values and archive-row counts for an unrejected replay.
4. Create one active rejection for `nitrate_mgl` using the exact source
   station, serial, timestamp, and a QARTOD flag. Confirm only the public
   `nitrate_mgl` becomes NULL, its paired QC value is retained, and the private
   row remains unchanged.
5. Re-run the real writer and separately replay the private source row. In
   both cases, confirm the active rejection prevents public restoration and
   that an unrelated public row remains writable.
6. Reinstatement must be metadata-only: the public value remains NULL until a
   later legitimate public replay restores it. Test a rolled-back rejection
   creation and verify both registry/public state and any archive side effects
   roll back together.
7. Exercise a blank serial fixture. The exact private source row must still
   suppress the rejected public parameter; the raw serial remains unchanged.
8. Record `sunav2_count_active_rejections(source_station, serial, m_date)`
   before and after rejection/reinstatement and compare it with the affected
   parameter count.

## Exit criteria

The clone report must include SQL/writer versions, all inputs, row-level
assertions, archive counts and OLD-row payload behavior for the actual
application name, role/permission results, and all legacy SUNA paths found.
Production trigger activation remains blocked until the owner accepts that
report and separately authorizes deployment.
