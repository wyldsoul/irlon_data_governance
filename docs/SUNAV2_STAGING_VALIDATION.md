# SUNA v2 realistic staging validation

`tests/sunav2/test_realistic_staging.sql` is a disposable PostgreSQL 12
simulation, not a production deployment or an invocation of the R writer.
Its fixture was copied from a production read-only query on 2026-08-19:
`_IRL-VB_SUNA`, serial `612`, `2026-08-19 20:00 UTC`, mapping to `IRL-VB-WQ`.

It represents the production SUNA objects relevant to suppression: the row-id
default, nullable operational columns used by the writer/archive function,
station foreign key, unique `(station,m_date)` constraint, station/depth/date
index, archive table, and the enabled `archive_trigger_sunav2` BEFORE UPDATE
trigger. The archive function's actual application-name gate is represented
exactly: `suna_ascii_process_recurring_final.R`.

The current writer instead sets `suna_ascii_tscorrection_recurring_final.R`.
Thus its normal current path does not produce archive rows through that gate.
When the historic gate is simulated, each public or private replay under an
active rejection produces an archive row containing the OLD public row. This
is a staging hold point, not a reason to weaken suppression.

The test proves the private-first/public-upsert SQL shape, rejection, direct
public guard, private replay, reinstatement, QARTOD flag application,
suppression-count reporting, and rollback atomicity. It does not invoke the R
writer or prove production-only permissions, all legacy paths, or deployment
behavior.
