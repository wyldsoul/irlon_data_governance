# Smallest SBE37 writer integration

This document concerns the SBE37 enforcement module only. The central registry
is generic; future instrument modules will define their own identity and mapping
contracts rather than reuse SBE37's private-station or serial conventions.
The registry stores the applicable IRLON QARTOD rollup: `1 = bad`,
`2 = suspect`, `3 = good`.

This is a reviewed patch plan, not an edit to either live writer. Both files are already part of a dirty `sbe37_ascii` worktree and must be rebased against their owner’s pending changes.

The recurring writer (`R/sbe37_ascii_process_recurring_final.R`, public loop around line 2490) and manual writer (`R/manual_sbe37_ascii_process_recurring_final.R`, public loop around line 1099) have the same shape: they calculate `newdata` with `serial_number_sbe37`, build public/private payloads, then currently upsert every public row before every private row. That order is incompatible with evidence-based public identity validation.

The minimal safe integration is, per row, **private upsert first**, followed by one public SQL statement that both establishes identity and performs the public upsert. Preserve `serial_number_sbe37` as a payload field in both data frames.

```r
WITH identity AS MATERIALIZED (
  SELECT sbe37_set_public_write_identity(<private_station>, <serial>)
), suppression AS MATERIALIZED (
  SELECT sbe37_count_active_rejections(<private_station>, <serial>, <m_date>) AS n
), candidate (...) AS (
  VALUES (...the existing public payload values...)
), upsert AS (
  INSERT INTO seabird_sbeeco (...) SELECT c.* FROM candidate c CROSS JOIN identity
  ON CONFLICT (station, m_date) DO UPDATE SET ...the existing assignments...
  RETURNING 1
)
SELECT n FROM suppression CROSS JOIN upsert;
```

The `CROSS JOIN identity` is required: it makes the materialized identity CTE execute in the same statement/transaction as the guarded upsert. Read the returned `n` and add it to the run total. This produces `N rejected public parameter values suppressed` without relying on session context surviving autocommit. A separate `set identity; then upsert` sequence is unsafe and must not be used.

The private payload/upsert in both writers must also include `serial_number_sbe37`. At present it is calculated in `newdata` but omitted from both the `private <- select(...)` list and the `INSERT INTO seabird_sbe37` column/value/update lists. Add it to the private payload and the private `INSERT` column/value/`ON CONFLICT DO UPDATE` assignment. Without it, a future replay cannot be tied to the instrument serial. This is required before enabling the database trigger.

Every active rejection identity requires that serial. If an hourly observation is
temporarily missing `serial_number_sbe37`, do not create or apply a serial-less
rejection identity; resolve the serial from an approved source or deployment
history first, or fail closed.

Do not infer the serial from `_IRL-…_SBE37`: that station string contains no serial number. Do not set a session-wide context once at process startup: each row may have a different serial.
