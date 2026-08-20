# Smallest SBE37 writer integration

This document concerns the SBE37 enforcement module only. The central registry
is generic; future instrument modules will define their own identity and mapping
contracts rather than reuse SBE37's private-station or serial conventions.
The registry stores the applicable IRLON QARTOD rollup: `1 = bad`,
`2 = suspect`, `3 = good`.

This is a reviewed patch plan, not an edit to either live writer. Both files are already part of a dirty `sbe37_ascii` worktree and must be rebased against their owner’s pending changes.

The recurring writer (`R/sbe37_ascii_process_recurring_final.R`, public loop around line 2490) and manual writer (`R/manual_sbe37_ascii_process_recurring_final.R`, public loop around line 1099) have the same shape: they calculate `newdata` with `serial_number_sbe37`, build public/private payloads, then currently upsert every public row before every private row. That order is incompatible with evidence-based public identity validation.

The minimal safe integration is, per row, **private upsert first**, followed by the public upsert. The trigger derives source identity from the mapped private station and timestamp. Preserve `serial_number_sbe37` as provenance when the writer has it, but do not make it a public-write prerequisite.

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

The private payload/upsert should include `serial_number_sbe37` whenever the writer has it, preserving provenance for manual ASCII and complete real-time rows. Its absence must not prevent a replay from being tied to the unique source observation.

For SBE37, active rejection identity is the unique source observation. If an
hourly observation omits `serial_number_sbe37`, retain the raw blank and apply
the rejection using source station, timestamp, and public parameter.

Do not infer the serial from `_IRL-…_SBE37`: that station string contains no serial number. Do not set a session-wide context once at process startup: each row may have a different serial.
