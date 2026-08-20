# SBE37 manual live-deployment runbook (prepared; not executed)

This is a manual-run guide only. It does **not** authorize production changes.
No command in this document has been run as a production write by Codex.

## Scope and current preflight evidence

Read-only production inspection on 2026-08-20 confirmed:

- `public.seabird_sbe37`, `public.seabird_sbeeco`, and
  `public.seabird_seafetv1` exist;
- each has unique `row_id` and unique `(station,m_date)` keys;
- the columns used by the reviewed SQL exist, with `row_id integer` (the SQL
  records it safely as `bigint`);
- the live tables currently have their archive triggers only, not the proposed
  governance triggers;
- both SBE37 archive functions gate on
  `application_name = 'sbe37_ascii_process_recurring_final.R'`.

The code has passed the complete disposable PostgreSQL 12 regression suite,
including private preservation, blank serial provenance, replay protection,
rollback, SBE37 temperature → salinity/dissolved-oxygen, matching SeaFET pH,
and no-SeaFET-source behavior. This is not restored-production-clone proof.

## Mandatory approval boundary

The reviewed SBE37 temperature rule creates a SeaFET pH child only when the
matching private SeaFET source row exists. Therefore the deployment unit is:

1. generic registry + SBE37 module:
   `sql/sbe37_public_parameter_suppression.sql`;
2. SeaFET module:
   `sql/seafetv1/public_parameter_suppression.sql`.

Both must be installed in **one approved transaction**, in that order. The
SBE37 function references SeaFET functions for the pH child. Do not deploy the
current SBE37 SQL alone and then enter a temperature rejection: it would have
an unresolved runtime dependency and SeaFET replay would not be governed.

If approval is restricted to SBE37 alone, stop here and obtain a reviewed
SBE37-only variant that deliberately omits the SeaFET pH rule. Do not edit the
live script ad hoc.

## Before the maintenance window

1. Obtain explicit approval for the two-module scope, trigger creation, writer
   pause, and one approved test rejection.
2. Use an immutable reviewed checkout of this repository. Record its commit
   and a checksum of both SQL files. Do not use a worktree with unrelated,
   unreviewed changes as the deployment source.
3. Complete a restored-production-clone rehearsal of the exact commands below,
   including a normal SBE37 writer replay and archive observation.
4. Confirm the SBE37 and SeaFET writers are stopped for the window. This
   changes no cron configuration; it is an operational pause only.
5. Capture an ordinary backup/snapshot according to the approved database
   recovery procedure.

## Read-only preflight

From the repository root, have the operator run:

```bash
PGOPTIONS='-c default_transaction_read_only=on' \
psql -X -v ON_ERROR_STOP=1 "$IRLON_PRODUCTION_DSN" \
  -f sql/sbe37_live_deployment_preflight.sql
```

Stop if any required table/column/key is absent, the registry already exists,
or an `sbe37_*` / `seafetv1_*` governance object already exists. Those are a
migration/reconciliation task, not a safe first deployment.

Also record the live DDL before changing it:

```bash
pg_dump --schema-only --table=public.seabird_sbe37 \
  --table=public.seabird_sbeeco --table=public.seabird_seafetv1 \
  "$IRLON_PRODUCTION_DSN" > prechange_sbe37_governance_schema.sql
```

## Manual deployment transaction

Use `psql -X` so no user startup file changes the session. Set the expected
writer name only for the deployment session; this makes any archive effects
visible and is part of the clone rehearsal. Do **not** substitute a different
application name silently.

```sql
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
SET LOCAL search_path = public;
SET LOCAL application_name = 'sbe37_ascii_process_recurring_final.R';

\i sql/sbe37_public_parameter_suppression.sql
\i sql/seafetv1/public_parameter_suppression.sql

-- Run the verification queries below before COMMIT.
```

In the same transaction, verify all expected objects exist and no unexpected
rows have been registered:

```sql
SELECT count(*) AS rejection_rows FROM rejected_observations;
SELECT indexname FROM pg_indexes
 WHERE schemaname='public' AND tablename='rejected_observations'
 ORDER BY indexname;
SELECT tgrelid::regclass AS table_name, tgname, tgfoid::regprocedure
  FROM pg_trigger
 WHERE NOT tgisinternal
   AND tgname IN ('sbe37_guard_rejected_public_parameters',
                  'sbe37_reapply_rejected_public_parameters',
                  'seafetv1_guard_rejected_public_parameters',
                  'seafetv1_reapply_rejected_public_parameters')
 ORDER BY 1,2;
SELECT conname, pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid='public.rejected_observations'::regclass;
```

Expected: zero rejection rows; both partial unique indexes; four governance
triggers; and `qc_flag IN (1, 2, 3)`. If any result differs, run `ROLLBACK;`
and stop. Otherwise, obtain the operator’s explicit final approval and run
`COMMIT;`.

## Post-commit verification and controlled test

1. With writers still paused, verify the objects again in a new session.
2. Create **one separately approved, disposable test rejection** through
   `reject_sbe37_public_parameter(...)`, against a known staging/controlled
   source observation—not historical operational data.
3. Replay that source using the normal writer path. Verify the private SBE37
   row remains unchanged, only the rejected public value is NULL, and its
   paired `qc_*` field equals the chosen QARTOD flag.
4. For a temperature test, verify the two SBE37 child decisions and—only if a
   matching private SeaFET row exists—the SeaFET pH child; all must share the
   same flag and parent link.
5. Verify archive row counts and trigger errors. The SBE37 archive gate is the
   expected recurring-writer application name above.
6. Reinstate the approved test decision. Verify its children become inactive;
   then use a normal replay to restore public values. Do not expect
   reinstatement itself to reconstruct values.
7. Resume writers only after results are reviewed and approved.

## Abort and rollback

Before `COMMIT`, use `ROLLBACK;` for any unexpected preflight/verification
result. After commit, do not drop the registry or triggers casually: preserve
the audit history and use an approved incident rollback plan. The safe first
response is to pause affected writers and assess the exact live state.
