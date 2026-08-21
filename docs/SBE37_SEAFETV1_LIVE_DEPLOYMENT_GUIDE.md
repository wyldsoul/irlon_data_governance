# SBE37 / SeaFET v1 governance — live deployment guide (operator runbook)

This is the **command-by-command** operator guide for deploying the SBE37 and
SeaFET v1 public-parameter suppression modules to the production `irlon`
database. It assumes you are comfortable with Linux, SSH, `psql`, and Git, and
tells you exactly what to run, where to run it, what success looks like, and
when to stop.

For the *design rationale* (why the dependency graph looks the way it does,
why the registry is shaped this way), see:

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — generic registry design
- [`SBE37_PUBLIC_PARAMETER_SUPPRESSION.md`](SBE37_PUBLIC_PARAMETER_SUPPRESSION.md) — SBE37 module, full dependency-graph evidence
- [`SEAFETV1_PUBLIC_PARAMETER_SUPPRESSION.md`](SEAFETV1_PUBLIC_PARAMETER_SUPPRESSION.md) — SeaFET v1 module
- [`SBE37_MANUAL_LIVE_DEPLOYMENT_RUNBOOK.md`](SBE37_MANUAL_LIVE_DEPLOYMENT_RUNBOOK.md) — prior narrative runbook and recorded preflight history; this document supersedes it as the step-by-step execution guide, but the recorded preflight evidence there is still relevant background

**This document does not authorize production changes by itself.** Every SQL
block below must be run manually by you, the operator, after the approvals in
Phase 0 are in hand.

---

## 0. Environment and access reference

| Item | Value |
|---|---|
| Deployment repo host | `lobolinux` (this session's `hostname` reports `lobolinuxnew` — confirm you are on the correct, approved deployment host before proceeding; if these don't match your expectation, STOP and resolve the discrepancy first) |
| Repo path | `/home/bbotson/irlon.org/irlon-data-governance` |
| Production DB host (real) | `irlon.org` |
| Production DB, as reached from this host | `localhost:2222`, via an SSH local port-forward |
| Production database name | `irlon` |
| Production DB user | `postgres` |
| Production PostgreSQL version | 12 |
| SSH tunnel command (confirmed from the current production writer, `sbe37_ascii/R/sbe37_ascii_process_recurring_final.R`) | `ssh -L2222:localhost:5432 -N -T bbotson@irlon.org` |

The tunnel command above is not invented for this guide — it is the exact
command the real recurring SBE37 writer falls back to when port 2222 isn't
already open (`sbe37_ascii_process_recurring_final.R`, ensure-tunnel logic).
**Do not use port 3334, 55432, or any other port for production** — those
belong to unrelated databases (a `manta`-side geo/report DB and past
restored-clone rehearsal work, respectively) and are out of scope here.

Check whether the tunnel is already up before starting a new one:

```bash
nc -z -w3 localhost 2222 && echo "TUNNEL UP" || echo "TUNNEL DOWN"
```

If `TUNNEL DOWN`, start it in the background and re-check:

```bash
ssh -L2222:localhost:5432 -N -T bbotson@irlon.org &
sleep 3
nc -z -w3 localhost 2222 && echo "TUNNEL UP" || echo "TUNNEL DOWN"
```

**STOP if** the tunnel does not come up, or if you already see more than one
`ssh -L2222:localhost:5432` process running (`ps aux | grep '2222'`) — kill
stray duplicates before proceeding rather than layering another one on top.

Every `psql` command in this guide against production uses exactly:

```
psql -X -h localhost -p 2222 -U postgres -d irlon ...
```

`-X` disables any `.psqlrc` that could silently change session behavior. If
`psql` ever prompts you for a password unexpectedly on this connection, that
is itself a **STOP** signal — the existing writers connect without a password
prompt (credentials are already resolved via the host's own configuration),
so a surprise prompt means something about the target or the tunnel is not
what you expect.

---

## 1. Phase 1 — Confirm the exact code to deploy

Run from the repo root, on the deployment host:

```bash
cd /home/bbotson/irlon.org/irlon-data-governance

git status --short
git branch --show-current
git rev-parse HEAD
git diff --check
```

**Expected result:**
- `git branch --show-current` → `main`
- `git rev-parse HEAD` → the commit you and your reviewer agreed is the
  approved deployment baseline (at the time this guide was written: `ee38c8266d1a80a1be91660edf1c55f490cd23cd`)
- `git diff --check` → **no output**, exit code 0 (no whitespace errors or
  conflict markers)
- `git status --short` → shows the reviewed, currently-uncommitted governance
  files as modified/untracked (see below). **This is expected right now** —
  the reviewed implementation has not yet been committed as of this guide's
  writing.

**STOP if** `git branch --show-current` is not `main`, if `git diff --check`
prints anything, or if `git status --short` shows files you don't recognize
from the review (e.g. unrelated in-progress work from another task).

### 1.1 Commit the reviewed state before deploying

Because `git status --short` currently shows the reviewed SQL/docs/tests as
uncommitted changes, **do not deploy directly from an uncommitted working
tree.** Before the maintenance window:

1. Have your reviewer sign off on the current diff (`git diff`, plus the new
   untracked files under `sql/` and `tests/`).
2. Commit that reviewed state to `main` yourself, following your team's normal
   commit process. This becomes the deployment commit.
3. Re-run the four commands above against the **new** HEAD and confirm they
   still pass.
4. Record that commit hash in the deployment log (Section 10). Every hash and
   command below assumes you are running from that exact, committed,
   `git status --short`-clean tree — not from a dirty working tree.

This guide itself does not commit anything and was written without assuming
which exact hash the eventual deployment commit will have — treat the
placeholder `<DEPLOY_COMMIT>` below as "the commit hash you recorded in step
3 above."

### 1.2 Record artifact hashes

```bash
sha256sum \
  sql/rejected_observations_schema.sql \
  sql/deploy_sbe37_seafetv1_clean.sql \
  sql/deploy_sbe37_seafetv1_upgrade.sql \
  sql/sbe37_public_parameter_suppression.sql \
  sql/seafetv1/public_parameter_suppression.sql \
  docs/SBE37_SEAFETV1_LIVE_DEPLOYMENT_GUIDE.md
```

Record all six hashes in the deployment log verbatim before touching
production. `sql/deploy_sbe37_seafetv1_clean.sql` is included because — per
Phase 3 below — the live deployment may turn out to be a clean install, not
an upgrade; record both wrapper hashes regardless of which path you end up
taking, so the log is complete either way.

**STOP if** any of these files fail to hash (missing file) or if the hashes
don't match what your reviewer signed off on.

---

## 2. Phase 2 — Read-only production preflight

This phase **only reads** from production. It opens a read-only transaction
and ends with `ROLLBACK` — nothing it does can mutate anything.

```bash
cd /home/bbotson/irlon.org/irlon-data-governance

PGOPTIONS='-c default_transaction_read_only=on' \
psql -X -h localhost -p 2222 -U postgres -d irlon \
  -v ON_ERROR_STOP=1 \
  -f sql/sbe37_live_deployment_preflight.sql \
  2>&1 | tee "preflight_$(date -u +%Y%m%dT%H%M%SZ).log"
```

### 2.1 What this checks, and what to expect

The script (`sql/sbe37_live_deployment_preflight.sql`) runs these queries, in
order, inside `BEGIN READ ONLY; ... ROLLBACK;`:

1. **Identity check** — `current_database()`, `current_user`,
   `current_setting('default_transaction_read_only')`, `now()`.

   **Expected:**
   ```
        database_name      | connected_role | default_read_only |          checked_at
   ----------------------------+----------------+--------------------+-------------------------------
    irlon                      | postgres       | on                 | <current timestamp>
   ```

   > ## STOP — do not proceed unless `database_name` is *exactly* `irlon`
   > If `database_name` is anything else — `irlon_geo`, `irlon_governance_rehearsal`,
   > `postgres`, or anything you don't immediately recognize as production —
   > **STOP**. Do not continue this guide. Close the connection, re-verify the
   > tunnel target, and start Phase 2 over.
   >
   > If `default_read_only` is not `on`, the `PGOPTIONS` environment variable
   > did not take effect — **STOP** and fix the shell invocation before
   > re-running; do not proceed on an ambiguous read-only guarantee.

2. **Required columns on `seabird_sbe37`, `seabird_sbeeco`, `seabird_seafetv1`.**
   Expected: all three tables listed, each with a comma-separated column list
   including `row_id`, `station`, `m_date`, and the instrument-specific
   columns (`serial_number_sbe37` / `serial_number_seafet`, `instrument`, the
   eight SBE37 public parameters and their `qc_*` pairs, `ph_tempsal` /
   `qc_ph_tempsal`).

   **STOP if** any of the three tables is missing, or is missing a column the
   SQL modules require — that is a schema-drift problem to resolve before any
   deployment, not something to work around live.

3. **Unique constraints.** Expected: a unique constraint per table covering
   `(station, m_date)` (exact constraint name may vary).

   **STOP if** no such unique constraint exists on any of the three tables —
   several of the module's functions rely on `(station, m_date)` being unique
   per source table.

4. **Existing non-internal triggers.** Expected (as of the last recorded
   preflight, 2026-08-20): only the pre-existing **archive** triggers on
   `seabird_sbe37` and `seabird_sbeeco` — none of the governance trigger names
   this deployment is about to create.

   **STOP and investigate (do not assume upgrade or clean install) if** you
   see any trigger named `sbe37_guard_rejected_public_parameters`,
   `sbe37_reapply_rejected_public_parameters`,
   `seafetv1_guard_rejected_public_parameters`, or
   `seafetv1_reapply_rejected_public_parameters` already present. That means
   someone has already partially deployed this — go to Phase 3 with extreme
   care and reconcile before doing anything else.

5. **`registry_preflight`** — the single most important line in this output.
   It directly tells you `PASS: rejected_observations is absent; first
   deployment is possible` or `STOP: rejected_observations already exists;
   compare its DDL before proceeding`. **This is the line that decides which
   branch of Phase 3 you take — read it carefully, do not skip past it.**

6. **Existing `sbe37_*` / `seafetv1_*` functions.** Expected (matching a
   `registry_preflight` of `PASS`): **zero rows**. If this list is non-empty
   while `registry_preflight` says `PASS`, that is an inconsistent state —
   **STOP** and reconcile before proceeding.

**STOP if** the script itself errors out (`ON_ERROR_STOP=1` will abort the
whole script on the first SQL error) — do not re-run with looser error
handling; investigate the actual error first.

---

## 3. Phase 3 — Decide: clean install or upgrade

**Do not assume either path. Decide this from the Phase 2
`registry_preflight` line you just captured, every time.**

The last recorded preflight against production (2026-08-20, documented in
[`SBE37_MANUAL_LIVE_DEPLOYMENT_RUNBOOK.md`](SBE37_MANUAL_LIVE_DEPLOYMENT_RUNBOOK.md))
found `rejected_observations` **absent** on production — meaning, as of that
date, this would be a **CLEAN INSTALL**, not an upgrade. Restored-clone
rehearsal validated the *upgrade* path against a clone that already had a
registry from earlier rehearsal work — that proves the upgrade wrapper is
safe and correct, but it is not evidence about production's current state.
**Trust today's live Phase 2 output, not this paragraph, when you actually
deploy.**

- **If `registry_preflight` says `PASS: rejected_observations is absent`** →
  take the **CLEAN INSTALL** path (Section 4A). This is the expected case
  based on the most recent evidence.
- **If `registry_preflight` says `STOP: rejected_observations already
  exists`** → take the **UPGRADE** path (Section 4B), and additionally
  compare the existing registry's DDL (`\d rejected_observations` in a
  read-only session) against `sql/rejected_observations_schema.sql` before
  proceeding, since an unexpected pre-existing registry needs to be
  understood, not just assumed compatible.

### Why we never rerun the combined first-install SQL against an existing registry

`sql/rejected_observations_schema.sql` issues a bare `CREATE TABLE
rejected_observations (...)`. If that table already exists — which it will
on any second-or-later deployment, or after a genuine first install has
already happened — this statement fails outright with `relation
"rejected_observations" already exists`, aborting the whole script. Even if
it *didn't* fail, rerunning first-install DDL is never the right tool for
updating an existing installation: it has no ability to preserve the
existing rows, their `active`/`parent_rejection_id` state, or their
`rejected_at`/`reinstated_at` audit history — a `CREATE TABLE` has nothing to
preserve *from*. This is exactly why `sql/deploy_sbe37_seafetv1_upgrade.sql`
exists as a separate wrapper: it contains **only** `CREATE OR REPLACE
FUNCTION` statements and `DROP TRIGGER IF EXISTS` / `CREATE TRIGGER` pairs —
it never touches `rejected_observations` itself, so it is always safe to
rerun against a database that already has real rejection history.

---

## 4A. Clean install path

Use this only if Phase 2's `registry_preflight` said `PASS`.

### 4A.1 Pre-deployment snapshot (evidence capture)

Even on a clean install, capture a snapshot — it proves the "before" state
and gives you something to diff against later if anything looks wrong.

```bash
cd /home/bbotson/irlon.org/irlon-data-governance
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVID="deployment_evidence/${STAMP}"
mkdir -p "$EVID"
```

`deployment_evidence/` is a new convention introduced by this guide — it does
not exist elsewhere in the repo yet. **Do not `git add` anything under it.**
It will contain real production query output; keep it local, and handle it
under your organization's normal data-handling policy, not through this
repository's git history.

```bash
psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' -c \
  "SELECT to_regclass('public.rejected_observations') AS registry_present;" \
  | tee "$EVID/before_registry.txt"

psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' -c \
  "SELECT tgrelid::regclass AS table_name, tgname, tgenabled
     FROM pg_trigger t
    WHERE NOT t.tgisinternal
      AND tgrelid::regclass::text IN ('seabird_sbe37','seabird_sbeeco','seabird_seafetv1')
    ORDER BY 1,2;" \
  | tee "$EVID/before_triggers.txt"

psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' -c \
  "SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND (proname LIKE 'sbe37\_%' ESCAPE '\' OR proname LIKE 'seafetv1\_%' ESCAPE '\')
    ORDER BY 1;" \
  | tee "$EVID/before_functions.txt"
```

**Expected:** `registry_present` → blank/`(1 row)` with a null value;
`before_triggers.txt` → only the pre-existing archive triggers;
`before_functions.txt` → empty.

### 4A.2 Apply the clean install

```bash
cd /home/bbotson/irlon.org/irlon-data-governance
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"  # reuse the same $STAMP as above if still in the same shell
psql -X -h localhost -p 2222 -U postgres -d irlon \
  -v ON_ERROR_STOP=1 \
  -f sql/deploy_sbe37_seafetv1_clean.sql \
  2>&1 | tee "deployment_evidence/${STAMP}/deploy_clean_install.log"
```

`sql/deploy_sbe37_seafetv1_clean.sql` runs, in one transaction:
`BEGIN; SET LOCAL search_path = public; \ir rejected_observations_schema.sql;
\ir seafetv1/public_parameter_suppression.sql; \ir sbe37_public_parameter_suppression.sql; COMMIT;`
SeaFET is installed before SBE37 because the SBE37 module's salinity-to-pH
dependency function calls SeaFET functions (`seafetv1_public_station`,
`seafetv1_resolve_serial`, `seafetv1_apply_active_rejections`) that must
already exist.

**Expected output shape** (exact object counts below are the current,
verified count — do not treat the numbers as approximate if they don't
match):

```
BEGIN
SET
CREATE TABLE
CREATE INDEX
CREATE INDEX
CREATE FUNCTION      <- seafetv1 module: 8 functions
...
DROP TRIGGER          <- "does not exist, skipping" NOTICE is normal here on a clean install
CREATE TRIGGER
DROP TRIGGER
CREATE TRIGGER
CREATE FUNCTION      <- sbe37 module: 12 functions
...
DROP TRIGGER
CREATE TRIGGER
DROP TRIGGER
CREATE TRIGGER
COMMIT
```

The `DROP TRIGGER IF EXISTS ... ; NOTICE: trigger "..." does not exist,
skipping` lines are expected and harmless on a clean install — the module SQL
always issues an explicit drop-then-create for its own triggers, whether or
not they previously existed, so the trigger-recreation logic is identical on
first install and every later reapply.

**STOP if:**
- Any line starts with `ERROR`.
- The final line is not `COMMIT` (if the script errored, `psql -v
  ON_ERROR_STOP=1` will have aborted before reaching `COMMIT`, and you should
  see the transaction implicitly rolled back — verify with a fresh read-only
  session that `rejected_observations` does *not* exist before treating it as
  safe to retry).
- You see any `DROP TABLE`, `TRUNCATE`, or `DELETE` referencing
  `rejected_observations` anywhere in the output — none of the reviewed SQL
  contains these, so seeing one means you are not running the file you think
  you are running.

Go to Section 5 (post-deployment verification) after a confirmed `COMMIT`.

---

## 4B. Upgrade path

Use this only if Phase 2's `registry_preflight` said `STOP: rejected_observations
already exists` — meaning a registry with real (or rehearsal) history is
already there and must be preserved.

### 4B.1 Pre-deployment snapshot (evidence capture)

This is the step that lets you *prove*, after the upgrade, that nothing in
the registry changed.

```bash
cd /home/bbotson/irlon.org/irlon-data-governance
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVID="deployment_evidence/${STAMP}"
mkdir -p "$EVID"

psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' <<'SQL' | tee "$EVID/before_registry.txt"
SELECT count(*) AS rejected_observations_count FROM rejected_observations;
SELECT md5(string_agg(t::text, ',' ORDER BY rejection_id))
  FROM (SELECT rejection_id,source_table,source_row_id,public_parameter,active,
               parent_rejection_id,qc_flag FROM rejected_observations) t;
SELECT rejection_id,source_table,source_row_id,public_table,source_station,public_station,
       instrument_type,instrument_serial,m_date,public_parameter,qc_flag,active,
       parent_rejection_id,rejected_by,reinstated_by,reinstatement_reason
  FROM rejected_observations ORDER BY rejection_id;
SQL

psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' -c \
  "SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
     FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
      AND p.proname ~ '^(sbe37_|reject_sbe37|reinstate_sbe37|seafetv1_|reject_seafetv1|reinstate_seafetv1)'
    ORDER BY p.proname;" \
  | tee "$EVID/before_functions.txt"

psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' -c \
  "SELECT c.relname AS table_name, t.tgname, t.tgenabled
     FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE NOT t.tgisinternal AND n.nspname='public'
      AND (t.tgname LIKE 'sbe37%' OR t.tgname LIKE 'seafetv1%')
    ORDER BY 1,2;" \
  | tee "$EVID/before_triggers.txt"

psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' -c \
  "SELECT indexname, indexdef FROM pg_indexes
    WHERE schemaname='public' AND tablename='rejected_observations' ORDER BY indexname;" \
  | tee "$EVID/before_indexes.txt"

psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' -c \
  "SELECT tgrelid::regclass AS table_name, tgname, tgenabled
     FROM pg_trigger t WHERE NOT t.tgisinternal
      AND tgrelid::regclass::text IN ('seabird_sbe37','seabird_sbeeco','seabird_seafetv1')
    ORDER BY 1,2;" \
  | tee "$EVID/before_archive_triggers.txt"
```

**Record the registry checksum (the `md5(...)` value) and row count
somewhere you will look at again in 10 minutes** — that exact string is what
you compare against after the upgrade in Section 6. This is the same
checksum approach already proven against a restored clone (see
`SBE37_PUBLIC_PARAMETER_SUPPRESSION.md` and the rehearsal evidence it
references); it is not a new, unverified technique.

### 4B.2 Apply the upgrade

```bash
cd /home/bbotson/irlon.org/irlon-data-governance
psql -X -h localhost -p 2222 -U postgres -d irlon \
  -v ON_ERROR_STOP=1 \
  -f sql/deploy_sbe37_seafetv1_upgrade.sql \
  2>&1 | tee "deployment_evidence/${STAMP}/deploy_upgrade.log"
```

**Expected output shape:**

```
BEGIN
SET
CREATE FUNCTION           <- seafetv1: 8x CREATE OR REPLACE FUNCTION
DROP TRIGGER
CREATE TRIGGER
DROP TRIGGER
CREATE TRIGGER
CREATE FUNCTION           <- sbe37: 12x CREATE OR REPLACE FUNCTION
DROP TRIGGER
CREATE TRIGGER
DROP TRIGGER
CREATE TRIGGER
COMMIT
```

Every function line reads `CREATE FUNCTION` in `psql`'s tag output whether it
was a first `CREATE` or a `CREATE OR REPLACE` over an existing function —
that is normal `psql` behavior, not a sign the replace didn't happen (the SQL
source uses `CREATE OR REPLACE FUNCTION` throughout both modules).
`sql/deploy_sbe37_seafetv1_upgrade.sql` contains **no** `CREATE TABLE`, `DROP
TABLE`, `TRUNCATE`, `DELETE`, or index statements at all — it only replaces
functions and recreates the four governance triggers.

**STOP if:**
- Any line starts with `ERROR`.
- The final line is not `COMMIT`.
- You see `CREATE TABLE`, `DROP TABLE`, `TRUNCATE`, `DELETE`, or `CREATE
  INDEX`/`DROP INDEX` referencing `rejected_observations` anywhere — the
  upgrade wrapper must never touch the registry table or its indexes; seeing
  this means you are not running the file you think you are running.

Go to Section 6 (registry preservation check) after a confirmed `COMMIT`.

---

## 5. Post-deployment object verification (both paths)

Run this after either 4A or 4B completes with `COMMIT`. Open a fresh session
(do not reuse the deployment session) so you're verifying what actually
persisted, not what a still-open transaction merely staged.

```bash
psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' <<'SQL' | tee "deployment_evidence/${STAMP}/after_objects.txt"
SELECT to_regclass('public.rejected_observations') AS registry_present;

SELECT count(*) AS function_count
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
   AND p.proname IN ('sbe37_public_station','sbe37_source_station','sbe37_set_public_write_identity',
                      'sbe37_count_active_rejections','sbe37_apply_active_rejections',
                      'reject_sbe37_public_parameter','reinstate_sbe37_public_parameter',
                      'sbe37_create_temperature_dependents','sbe37_create_salinity_dependents',
                      'sbe37_create_pressure_dependents','sbe37_guard_public_parameter_write',
                      'sbe37_reapply_rejections_after_private_write','seafetv1_public_station',
                      'seafetv1_source_station','seafetv1_resolve_serial',
                      'reject_seafetv1_public_parameter','seafetv1_apply_active_rejections',
                      'reinstate_seafetv1_public_parameter','seafetv1_guard_public_parameter_write',
                      'seafetv1_reapply_rejections_after_private_write');

SELECT c.relname AS table_name, t.tgname, count(*) AS occurrences
  FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE NOT t.tgisinternal AND n.nspname='public'
   AND t.tgname IN ('sbe37_guard_rejected_public_parameters','sbe37_reapply_rejected_public_parameters',
                     'seafetv1_guard_rejected_public_parameters','seafetv1_reapply_rejected_public_parameters')
 GROUP BY 1,2 ORDER BY 1,2;

SELECT indexname FROM pg_indexes
 WHERE schemaname='public' AND tablename='rejected_observations' ORDER BY indexname;

SELECT c.relname AS table_name, t.tgname, t.tgenabled
  FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE NOT t.tgisinternal AND n.nspname='public'
   AND c.relname IN ('seabird_sbe37','seabird_sbeeco','seabird_seafetv1')
 ORDER BY 1,2;
SQL
```

**Expected exact results:**

| Check | Expected |
|---|---|
| `registry_present` | `rejected_observations` (not null/blank) |
| `function_count` | **20** (12 SBE37 + 8 SeaFET; verified against the current committed SQL — if this number differs, the deployed SQL does not match what this guide was written against, and you must reconcile before proceeding) |
| Trigger occurrences | exactly **4 rows, each with `occurrences = 1`** — `sbe37_guard_rejected_public_parameters` on `seabird_sbeeco`, `sbe37_reapply_rejected_public_parameters` on `seabird_sbe37`, `seafetv1_guard_rejected_public_parameters` and `seafetv1_reapply_rejected_public_parameters` both on `seabird_seafetv1` |
| Indexes | exactly **3**: `rejected_observations_pkey`, `rejected_observations_active_source_row_parameter_key`, `rejected_observations_active_legacy_parameter_key` |
| Table triggers | your 4 new governance triggers **plus** the pre-existing archive triggers on `seabird_sbe37`/`seabird_sbeeco` — archive triggers must still be present and enabled (`tgenabled = 'O'`) |

**STOP if** `function_count` is not exactly 20, if any trigger name has
`occurrences <> 1` (duplicate or missing), if the index count is not exactly
3, or if any pre-existing archive trigger is missing or shows
`tgenabled` other than `O` (origin — normally enabled).

---

## 6. Registry preservation check (upgrade path only)

Skip this section on a clean install — there is no prior registry state to
preserve. On the upgrade path, this is not optional.

```bash
psql -X -h localhost -p 2222 -U postgres -d irlon --no-psqlrc -A -F' | ' <<'SQL' | tee "deployment_evidence/${STAMP}/after_registry.txt"
SELECT count(*) AS rejected_observations_count FROM rejected_observations;
SELECT md5(string_agg(t::text, ',' ORDER BY rejection_id))
  FROM (SELECT rejection_id,source_table,source_row_id,public_parameter,active,
               parent_rejection_id,qc_flag FROM rejected_observations) t;
SQL
```

Compare directly against what you recorded in Section 4B.1:

- **`rejected_observations_count` before == after.**
- **The `md5(...)` checksum before == after, character for character.**

**Expected result: before checksum == after checksum.**

**STOP and investigate before any functional testing if they don't match.**
Do not proceed to smoke tests, do not resume writers, and do not attempt a
second "corrective" run of the upgrade script. A checksum mismatch means
either the upgrade script touched rows it shouldn't have (which the SQL as
reviewed does not do), or something else wrote to the registry concurrently
during the deployment window (e.g. a writer wasn't actually paused). Diagnose
which before doing anything else — this is the single highest-signal check
in the whole deployment.

If you need to go deeper than the checksum, diff the full row sets:

```sql
SELECT * FROM rejected_observations
EXCEPT
SELECT * FROM rejected_observations; -- placeholder: compare against your saved before_registry.txt row-by-row instead, since "before" only exists as a snapshot, not a live table
```

In practice this means visually diffing `before_registry.txt`'s row listing
against a fresh row listing, since the "before" state only exists as a
captured snapshot, not as a second live table you can `EXCEPT` against
in-database.

---

## 7. Post-deployment smoke tests

**Do not create long-lived fake production data, and do not run a full
writer replay immediately after deployment unless a defect is actually
suspected.** Every test below is read-only, or is wrapped in a transaction
you explicitly roll back. None of them require pausing writers any longer
than the deployment window you already arranged.

### A. Function existence and signature verification (read-only)

Already covered by Section 5's `function_count` check. No further action
needed here beyond confirming that check passed.

### B. Unsupported-parameter fail-closed check (transaction, rolled back)

**Why this is safe:** it never touches a real row. It inserts one throwaway
rejection registry row referencing the generic `hypothetical_*` fixture
identity pattern already used in `tests/test_sbe37_public_parameter_suppression.sql`
(not a real station), inside a transaction that is rolled back at the end —
no committed change of any kind.

```bash
psql -X -h localhost -p 2222 -U postgres -d irlon <<'SQL'
BEGIN;
SELECT reject_sbe37_public_parameter(
  '_SMOKE-TEST_SBE37', NULL, now(), 'not_a_real_parameter', 2,
  'post-deployment smoke test: unsupported parameter must fail', current_user
);
ROLLBACK;
SQL
```

**Expected:** an `ERROR: private SBE37 observation not found` (since
`_SMOKE-TEST_SBE37` doesn't exist) **or** — if you instead point this at a
real private station/timestamp you know exists — `ERROR: unsupported SBE37
public parameter: not_a_real_parameter`. Either error is the pass condition;
what matters is that the statement is rejected before any row is written, and
that the subsequent `ROLLBACK` leaves nothing behind. **STOP if this
`INSERT`/function call succeeds** — that means the fixed allowlist check in
`reject_sbe37_public_parameter` is not installed correctly.

**Must be rolled back:** yes — `ROLLBACK;` is already in the script above.
Verify nothing persisted:

```bash
psql -X -h localhost -p 2222 -U postgres -d irlon -c \
  "SELECT count(*) FROM rejected_observations WHERE source_station = '_SMOKE-TEST_SBE37';"
```

**Expected:** `0`.

### C. Parent/child dependency behavior on a known real observation (transaction, rolled back)

**Why this is safe:** it uses `SAVEPOINT`/`ROLLBACK TO SAVEPOINT` inside one
outer transaction that ends in `ROLLBACK`, on a real but carefully chosen
observation. Nothing about this test is ever committed. Pick one recent,
ordinary SBE37 observation you don't mind briefly seeing suppressed within a
transaction only you can see (other sessions never see uncommitted work).

```bash
psql -X -h localhost -p 2222 -U postgres -d irlon <<SQL
BEGIN;

-- Replace these three values with a real, current, ordinary observation
-- before running — do not use a placeholder here.
SELECT reject_sbe37_public_parameter(
  '_<STATION>_SBE37', '<SERIAL>', '<TIMESTAMP WITH TIME ZONE>',
  'pressure_water', 2, 'post-deployment smoke test: dependency behavior', current_user
) AS smoke_rejection_id \gset

-- pressure_water and its depth_instrument child should both now be NULL.
SELECT pressure_water, depth_instrument FROM seabird_sbeeco
 WHERE station = '<STATION>-WQ' AND m_date = '<TIMESTAMP WITH TIME ZONE>';

-- The depth_instrument child must exist and be blocked from independent reinstatement.
SELECT rejection_id AS depth_child_id FROM rejected_observations
 WHERE parent_rejection_id = :smoke_rejection_id AND public_parameter = 'depth_instrument' AND active \gset
SAVEPOINT blocked_child;
SELECT reinstate_sbe37_public_parameter(:depth_child_id, current_user, 'smoke test: expect block');
ROLLBACK TO SAVEPOINT blocked_child;

ROLLBACK;
SQL
```

**Expected:**
- `pressure_water` and `depth_instrument` both `NULL` after the rejection.
- `depth_child_id` resolves to a real row (dependency child was created).
- The `reinstate_sbe37_public_parameter(:depth_child_id, ...)` call raises
  `ERROR: cannot reinstate dependent rejection while parent rejection <id>
  remains active`.

**STOP if** either dependent creation or the reinstatement block doesn't
happen as described — that's a functional regression in the just-deployed
code, not a test artifact.

**Must be rolled back:** yes — the outer `ROLLBACK;` discards everything,
including the `reject_sbe37_public_parameter` call itself. Verify:

```bash
psql -X -h localhost -p 2222 -U postgres -d irlon -c \
  "SELECT pressure_water, depth_instrument FROM seabird_sbeeco
    WHERE station = '<STATION>-WQ' AND m_date = '<TIMESTAMP WITH TIME ZONE>';"
```

**Expected:** the same non-null values the row had before the smoke test —
confirming the rollback left production genuinely untouched.

### D. Read-only fallback

If, on the day, you or your reviewer judge test C too risky for any reason
(e.g. you're not fully confident a session-visible-only transaction is
acceptable under your change-control policy), skip it and rely on:

- Section 5's object verification, and
- Section 6's registry checksum match (upgrade path),

as sufficient evidence that the deployed code is byte-for-byte what passed
disposable-PostgreSQL-12 and restored-clone validation. This is a weaker
functional guarantee than test C, but it is zero-risk, and the disposable and
restored-clone test suites already proved this exact SQL's dependency
behavior extensively before today.

---

## 8. Writer monitoring

After deployment, resume the paused writers and watch their **next normal
run** — do not force an extra run purely to "test" the deployment.

- `/home/bbotson/irlon.org/sbe37_ascii/R/sbe37_ascii_process_recurring_final.R`
- `/home/bbotson/irlon.org/seafet_ascii/R/seafet_ascii_process_recurring_final.R`

**Expected normal behavior:**
- Ordinary (non-rejected) observations continue writing exactly as before —
  the guard triggers exit immediately for any row with no matching active
  rejection (`sbe37_guard_public_parameter_write` and
  `seafetv1_guard_public_parameter_write` both `RETURN NEW` at the top when
  there's nothing active for that row), so there should be no behavior change
  for ordinary data.
- The existing archive triggers on `seabird_sbe37` / `seabird_sbeeco` /
  `seabird_seafetv1` continue firing exactly as before — the governance
  triggers do not replace or bypass them.
- If a rejection is later entered (Section 9), that rejection's public value
  stays suppressed across the writer's normal recurring runs — it does not
  silently reappear.
- If a malformed active registry row somehow exists (should never happen
  through the reviewed API, only through a direct manual `INSERT`), both the
  public guard and the private reapply path fail closed with `ERROR:
  unsupported active SBE37 public parameter: ...` / `... SeaFET v1 public
  parameter exists for ...` rather than silently ignoring it.
- No unexpected `application_name` behavior: the archive triggers on
  `seabird_sbe37` gate on `application_name = 'sbe37_ascii_process_recurring_final.R'`
  (per the recorded preflight in `SBE37_MANUAL_LIVE_DEPLOYMENT_RUNBOOK.md`) —
  this deployment does not change that gate, so archive volume should look
  the same as before.

**Where to look:** this guide does not invent new log paths. Use the writer
scripts' own existing log locations under `/home/bbotson/irlon.org/sbe37_ascii/logs/`
and `/home/bbotson/irlon.org/seafet_ascii/logs/` — the same locations you
already monitor for these writers' normal recurring runs. If the writers
email a failure notification on error (both scripts have failure-email
logic), that is your fastest signal of a problem; do not wait for a manual
log check if a failure email arrives first.

**STOP condition post-deployment:** if the next SBE37 or SeaFET writer run
errors in a way it did not error before this deployment, pause that writer
again and go to Section 11 (rollback).

---

## 9. Dependency rules (what governance now enforces)

```
temperature_water
  -> salinity
      -> ph_tempsal   (SeaFET, only if a matching private SeaFET row exists)
  -> dissolved_oxygen

pressure_water
  -> depth_instrument
```

- **`ph_tempsal` is intentionally transitive through `salinity`.** A
  `temperature_water` rejection never creates a `ph_tempsal` child directly —
  it creates a `salinity` child, and *that* child creates the `ph_tempsal`
  grandchild. This means `ph_tempsal` always has exactly one
  `parent_rejection_id`, never two competing ones.
- **One rejection row has one parent.** `parent_rejection_id` is a single
  column, not a set — the schema itself makes multi-parent ambiguity
  impossible.
- **Direct child reinstatement is blocked while its immediate parent is
  active.** `reinstate_sbe37_public_parameter` / `reinstate_seafetv1_public_parameter`
  both raise `cannot reinstate dependent rejection while parent rejection
  <id> remains active` if you try. You only ever need to check the
  *immediate* parent — a row can never be active while its own direct parent
  is active, an invariant the recursive cascade below maintains.
- **Reinstating a top-level parent recursively releases every active
  descendant**, however many levels deep, in one call
  (`reinstate_sbe37_public_parameter` walks the full descendant tree, not
  just direct children).
- **Salinity-first, then temperature-second remains SAFE BUT
  PROVENANCE-LIMITED — this is intentional, not a defect.** If `salinity` is
  rejected standalone first (creating its own `ph_tempsal` child), and
  `temperature_water` is rejected afterward for the same observation, the
  temperature rejection's own attempt to create a `salinity` child silently
  no-ops against the registry's unique index — it does **not** adopt the
  pre-existing salinity rejection as its child. The earlier standalone
  `salinity`/`ph_tempsal` rejection stays fully independent: still active,
  still correctly enforced, still reinstated on its own separately from
  `temperature_water`. No suppressed value is ever exposed by this — the only
  imperfection is that `temperature_water`'s registry row carries no
  acknowledgment that salinity was already governed. See
  `SBE37_PUBLIC_PARAMETER_SUPPRESSION.md` for the full write-up and the
  restored-clone evidence behind this classification.
- **`oxygen_saturation_perc` is not a dependent of anything** in this
  module's scope — confirmed by production code, not omitted by oversight
  (see `SBE37_PUBLIC_PARAMETER_SUPPRESSION.md`).

---

## 10. Reinstatement operator workflow

Use this any time after go-live when a previously entered rejection needs to
be reversed.

### 10.1 Inspect the rejection row

```sql
SELECT rejection_id, source_table, source_station, public_station, m_date,
       public_parameter, qc_flag, active, parent_rejection_id,
       rejected_at, rejected_by, rejection_reason,
       reinstated_at, reinstated_by, reinstatement_reason
  FROM rejected_observations
 WHERE public_station = '<STATION>-WQ' AND m_date = '<TIMESTAMP>'
 ORDER BY rejection_id;
```

Note the `rejection_id` of the row you actually want to reinstate, and its
`parent_rejection_id` (if any).

### 10.2 Identify parents and children

```sql
-- Children of a given rejection:
SELECT rejection_id, public_parameter, active FROM rejected_observations
 WHERE parent_rejection_id = <rejection_id>;

-- Full ancestor chain of a given rejection (walk parent_rejection_id upward
-- by hand for one or two hops; chains in this design are at most three
-- levels deep: temperature_water -> salinity -> ph_tempsal).
```

If `parent_rejection_id` is not null and that parent is still `active`,
reinstating this row directly will fail — reinstate the topmost active
ancestor instead (see 10.3), which will release this row automatically.

### 10.3 Call the correct reinstatement function

For an SBE37-side rejection (source table `seabird_sbe37`) — this reinstates
the row **and its full active descendant subtree**:

```sql
SELECT reinstate_sbe37_public_parameter(
  <rejection_id>, '<your username>', '<specific, reviewed reinstatement reason>'
);
```

For a standalone SeaFET-side rejection (source table `seabird_seafetv1`,
i.e. one that is *not* a child of an SBE37 salinity/temperature rejection —
check `parent_rejection_id` and `source_table` first):

```sql
SELECT reinstate_seafetv1_public_parameter(
  '<private _SITE_SEAFETV1 station>', '<serial, or NULL>', '<m_date>',
  'ph_tempsal', '<your username>', '<specific, reviewed reinstatement reason>'
);
```

If the SeaFET row's `parent_rejection_id` points at an SBE37 salinity
rejection, reinstate through `reinstate_sbe37_public_parameter` on that
parent (or its own top-level ancestor) instead — the SeaFET row will be
released as part of that call.

### 10.4 Verify state after reinstatement

```sql
SELECT rejection_id, public_parameter, active, reinstated_at, reinstated_by, reinstatement_reason
  FROM rejected_observations
 WHERE rejection_id = <rejection_id> OR parent_rejection_id = <rejection_id>;
```

**Expected:** the target row and every descendant now `active = false`, each
with `reinstated_at`, `reinstated_by`, and `reinstatement_reason` populated.
Public values are still `NULL` at this point — reinstatement only changes
registry state, it does not touch `seabird_sbeeco` / `seabird_seafetv1`
directly.

### 10.5 Writer replay step

The numeric value only comes back once the normal source writer next
processes that observation (its private-table `AFTER` trigger reapplies
active rejections on every private write, and since there is no longer an
active rejection, nothing gets re-nulled). You do not need to force this —
either wait for the next normal recurring run, or, if urgency requires it,
run the writer's normal `--rerun`/reprocess path for that specific source
file through its ordinary operational procedure (outside the scope of this
governance-specific guide).

### 10.6 QARTOD step

See Section 11 below — do not expect the value's `qc_*` column to reflect
normal QC state yet after the writer replay.

### 10.7 Final QC verification

```sql
SELECT <parameter>, qc_<parameter> FROM seabird_sbeeco
 WHERE station = '<STATION>-WQ' AND m_date = '<TIMESTAMP>';
```

Confirm the numeric value is restored and non-null. The `qc_<parameter>`
value will still read the old rejection's `qc_flag` (1 or 2) until QARTOD
runs — that is expected; do not treat it as a governance defect.

---

## 11. QARTOD follow-up — MANDATORY, READ THIS

> ## Governance reinstatement does NOT itself restore normal QC state.
>
> This is the single most important operational caveat in this entire
> deployment. Do not skip it, and do not "fix" it by hand.

Current operational lifecycle:

```
rejection active
  -> public value NULL, qc_<parameter> = the rejection's chosen qc_flag (1 or 2)

reinstate
  -> rejection row becomes inactive (registry state only — no table value changes yet)

source writer replay
  -> numeric value restored to seabird_sbeeco / seabird_seafetv1

QARTOD run
  -> normal qc_* reevaluation happens
     (/home/bbotson/irlon.org/qartod/R/qartod_specific_update_recurring_v2_optimized.R)
```

Between "source writer replay" and the next QARTOD run, the numeric value is
correct and public, but `qc_<parameter>` can remain at the rejection's old
flag (1 = bad or 2 = suspect) even though the value itself is now a normal,
restored measurement. **This is expected, not a bug** — it is the documented
seam between this governance module and the separate QARTOD pipeline.

**Do not manually set `qc_<parameter>` to `3` (good) to "fix" this.** That
bypasses the actual QC evaluation QARTOD performs and can mask a genuinely
bad value. Let the next scheduled QARTOD run reevaluate it normally.

QARTOD's current process is manual/scheduled, not triggered automatically by
this governance module — this deployment does **not** add any automation
linking reinstatement to QARTOD, and building that integration is
out of scope for this task.

---

## 12. Rollback plan

### A. SQL deployment fails before `COMMIT`

If any step in Section 4A or 4B errors before reaching `COMMIT`,
`psql -v ON_ERROR_STOP=1` has already aborted the script; PostgreSQL rolls
the open transaction back automatically. There is nothing to undo manually.

**Verify:**
```bash
psql -X -h localhost -p 2222 -U postgres -d irlon -c \
  "SELECT to_regclass('public.rejected_observations') AS registry_present;"
```
On a failed clean install, expect `NULL` (nothing was created). On a failed
upgrade, expect the table still present, unchanged — rerun Section 4B.1's
snapshot and confirm the checksum still matches what you had before the
failed attempt. Diagnose the actual SQL error before retrying either path.

### B. SQL deployment commits, but post-checks (Section 5/6) fail

**Do not blindly drop the registry.** Even on what you believe is a clean
install, someone may have entered a real rejection in the few minutes since
`COMMIT` (which is exactly why writers stay paused through this whole
window). Preserve `rejected_observations` unconditionally at this stage.

Restore the prior function/trigger definitions from the last known-good
state:

- **If this deployment was a clean install and Section 5/6 caught the
  problem before any real rejection was ever entered through the new API**
  (confirm via `SELECT count(*) FROM rejected_observations;` — expect `0`),
  it is safe to drop everything this deployment created, in this order:
  ```sql
  BEGIN;
  DROP TRIGGER IF EXISTS sbe37_guard_rejected_public_parameters ON seabird_sbeeco;
  DROP TRIGGER IF EXISTS sbe37_reapply_rejected_public_parameters ON seabird_sbe37;
  DROP TRIGGER IF EXISTS seafetv1_guard_rejected_public_parameters ON seabird_seafetv1;
  DROP TRIGGER IF EXISTS seafetv1_reapply_rejected_public_parameters ON seabird_seafetv1;
  -- Then drop the functions and, only on a from-scratch clean install with
  -- zero real rejection rows, the registry table itself. List the exact
  -- function names from Section 5's function_count query before dropping
  -- them individually with DROP FUNCTION.
  ROLLBACK; -- review the exact statements with your reviewer before ever converting this to COMMIT
  ```
  Do this only with your reviewer present, and only after confirming
  `rejected_observations` has zero rows.

- **If this deployment was an upgrade** (registry already had real history
  before you started), or if any rejection row now exists that you cannot
  prove is safe to lose, do **not** drop the registry. Instead, restore the
  *previous* function/trigger definitions by materializing the prior
  committed SQL and reapplying it:
  ```bash
  cd /home/bbotson/irlon.org/irlon-data-governance
  mkdir -p /tmp/irlon-rollback
  git show <PRIOR_KNOWN_GOOD_COMMIT>:sql/seafetv1/public_parameter_suppression.sql \
    > /tmp/irlon-rollback/seafetv1_public_parameter_suppression.sql
  git show <PRIOR_KNOWN_GOOD_COMMIT>:sql/sbe37_public_parameter_suppression.sql \
    > /tmp/irlon-rollback/sbe37_public_parameter_suppression.sql
  psql -X -h localhost -p 2222 -U postgres -d irlon -v ON_ERROR_STOP=1 <<SQL
  BEGIN;
  \i /tmp/irlon-rollback/seafetv1_public_parameter_suppression.sql
  \i /tmp/irlon-rollback/sbe37_public_parameter_suppression.sql
  COMMIT;
  SQL
  ```
  `<PRIOR_KNOWN_GOOD_COMMIT>` is whatever commit was actually live in
  production *before* today's deployment. As of this guide's writing,
  nothing has ever been deployed to production, so there is no such prior
  commit yet for this first deployment — this branch of the rollback plan
  becomes actionable starting with the *next* future change after today's
  deployment succeeds. For today's rollback, if the upgrade path was somehow
  taken and needs reverting, the practical equivalent is: stop, do not
  attempt an automatic revert, and get your reviewer on a call before running
  anything further by hand — you are in genuinely novel territory (a
  pre-existing production registry that isn't described anywhere in this
  guide) and should not follow a generic script.

  This `git show <commit>:path` materialization pattern is the same one
  already proven in the repo's own old-schema-upgrade regression test
  (`tests/test_sbe37_seafetv1_old_schema_upgrade.sql`) — it is not a novel
  technique invented for this guide.

Verify after any rollback function/trigger restoration:
```bash
psql -X -h localhost -p 2222 -U postgres -d irlon -c \
  "SELECT count(*) FROM rejected_observations;"
```
Confirm the count matches what it was immediately before your rollback
action — the registry itself must be untouched by any function/trigger
rollback.

### C. A functional smoke test (Section 7) discovers a real defect

- **Stop writers only if the defect could cause them to write incorrect
  public data** (e.g. the guard trigger fails to suppress an active
  rejection). If the defect is narrower (e.g. a specific edge-case error
  message is wrong but suppression itself still works), you may not need to
  stop writers at all — use judgment with your reviewer, and write down the
  justification either way.
- **Do not delete the registry** under any circumstances at this stage —
  whatever rows exist are real audit history by the time you're running
  smoke tests against a committed deployment.
- Revert module functions/triggers via the same `git show <commit>:path`
  pattern as rollback path B above.
- After reverting, re-verify:
  - Section 5's object checks (should now show the *prior* function
    signatures/behavior, not today's),
  - that public/private table writes behave the way they did before today's
    deployment,
  - that archive triggers on all three tables are still firing normally.

---

## 13. Evidence / deployment record

Record all of the following in your deployment log (a plain text file is
fine — put it in the same `deployment_evidence/${STAMP}/` directory you
created in Section 4A.1/4B.1):

- [ ] Date/time (UTC) of deployment
- [ ] Operator name
- [ ] Git branch (`main`)
- [ ] Git commit hash actually deployed (the `<DEPLOY_COMMIT>` from Section 1.1)
- [ ] `git status --short` output at deployment time (should be clean)
- [ ] All six SHA256 hashes from Section 1.2
- [ ] Production PostgreSQL version confirmed in Section 2 (`12`)
- [ ] Full preflight output (Section 2 log file)
- [ ] Deployment path taken: CLEAN INSTALL or UPGRADE, and the
      `registry_preflight` line that determined it
- [ ] Pre-deployment registry count/checksum (upgrade path) or "N/A — clean
      install" (clean-install path)
- [ ] Deployment transaction log file (`deploy_clean_install.log` or
      `deploy_upgrade.log`), confirming `COMMIT`
- [ ] Post-deployment object verification output (Section 5)
- [ ] Post-deployment registry count/checksum, and confirmation it matches
      pre-deployment (upgrade path)
- [ ] Smoke-test results (which of A/B/C/D were run, and their outcomes)
- [ ] Next SBE37 writer run observed: timestamp, outcome
- [ ] Next SeaFET writer run observed: timestamp, outcome
- [ ] Explicit acknowledgment that the QARTOD caveat (Section 11) was read
      and understood
- [ ] Any anomalies, even minor ones, with enough detail for someone else to
      understand them later without asking you

---

## 14. Final GO / NO-GO checklist

**GO** only if every item below is true:

- [ ] Exact approved git state identified and committed (Section 1)
- [ ] `git diff --check` clean
- [ ] All six SQL/doc hashes recorded and matched to reviewer sign-off
- [ ] Read-only preflight (Section 2) passed, with `database_name = irlon`
      confirmed explicitly
- [ ] Deployment path (clean install vs. upgrade) determined from today's
      live `registry_preflight` output, not assumed
- [ ] Ordinary backup/snapshot captured per your organization's approved
      database recovery procedure (outside the scope of this repo)
- [ ] Writers confirmed paused for the deployment window
- [ ] Deployment transaction completed with a confirmed `COMMIT`
- [ ] Registry state preserved (upgrade path: checksum match; clean install:
      N/A)
- [ ] Post-deployment object verification shows exactly 20 functions, 4
      governance triggers (each occurring once), 3 indexes, and all
      pre-existing archive triggers still present and enabled
- [ ] Smoke tests (as many of A/B/C as you and your reviewer judged
      appropriate) passed
- [ ] Rollback path (Section 12) reviewed and understood by whoever is
      present during the window, before `COMMIT` — not looked up for the
      first time after something goes wrong

**NO-GO** if any item above fails, is skipped without an explicit, logged
justification, or is ambiguous. When in doubt, `ROLLBACK;` and stop — a
delayed deployment costs far less than a rushed one on a production database
that governs real public water-quality data.

---

## Related documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md)
- [`SBE37_PUBLIC_PARAMETER_SUPPRESSION.md`](SBE37_PUBLIC_PARAMETER_SUPPRESSION.md)
- [`SEAFETV1_PUBLIC_PARAMETER_SUPPRESSION.md`](SEAFETV1_PUBLIC_PARAMETER_SUPPRESSION.md)
- [`SBE37_MANUAL_LIVE_DEPLOYMENT_RUNBOOK.md`](SBE37_MANUAL_LIVE_DEPLOYMENT_RUNBOOK.md) — prior narrative runbook; recorded preflight history referenced above
- [`SBE37_PUBLIC_PARAMETER_SUPPRESSION_WRITER_INTEGRATION.md`](SBE37_PUBLIC_PARAMETER_SUPPRESSION_WRITER_INTEGRATION.md)
- [`SEAFETV1_WRITER_INTEGRATION.md`](SEAFETV1_WRITER_INTEGRATION.md)
