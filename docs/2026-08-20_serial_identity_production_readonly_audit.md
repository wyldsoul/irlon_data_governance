# Serial-identity production read-only audit — 2026-08-20

## Scope and safety

This audit used the existing localhost tunnel to the `irlon` PostgreSQL
database as `postgres`, with `default_transaction_read_only = on`, inside
explicit `BEGIN READ ONLY` transactions. It issued `SELECT` statements only.
It did not change production data, schema, triggers, files, or cron.

Scope: private/source partitions of SBE37, SUNA v2, SeaFET v1, Aquadopp, ECO,
and CO2ProCV, plus the identity-relevant unique indexes. `seabird_sbeeco` has
no serial-number column. For SBE37-owned parameters, its serial identity comes
from the corresponding `seabird_sbe37` private source row at mapped station and
timestamp; it must never be inferred from the public row itself.

## Aggregate findings

| Private source | Source rows | Blank/whitespace serial rows | Source `(station,m_date)` duplicate rows | Current-window blank rows (2026-05-20 through 2026-08-20 UTC) |
|---|---:|---:|---:|---:|
| `seabird_sbe37` | 394,876 | 32,769 | 0 | 2,493 / 16,940 (14.72%) |
| `seabird_sunav2` | 988,747 | 431,832 | 0 | 0 / 17,171 |
| `seabird_seafetv1` | 871,055 | 452,306 | 0 | 47 / 5,981 (0.79%) |
| `nortek_aquadopp` | 844,706 | 676,403 | 0 | 0 / 8,380 |
| `seabird_eco` | 424,044 | 15,563 | 4,762 | 131 / 17,894 (0.73%) |
| `prooceanus_co2procv` | 431,487 | 1,427 | 5 | 0 / 15,731 |

Blank serials are therefore a real historical condition in every currently
audited source family. For unique-source-row modules they are nullable
provenance, not a second or NULL-serial governance identity.
Recent SUNA and Aquadopp source rows had complete serial coverage in this
window, but that is an observation, not proof that future gaps cannot occur.

## SBE37 to SBE-ECO pairing

For the current audit window, 16,931 of 16,940 SBE37 private rows matched a
`seabird_sbeeco` public row by the documented source-to-public station mapping
and timestamp. Of those matches, 16,923 carried `instrument = 'SBE37/ECO'`.
The source serial was present for 14,440 matched public rows and blank for
2,491. Looking from the public side, 17,717 `SBE37/ECO` rows existed: 14,440
matched a private SBE37 row with serial, 2,483 matched a private SBE37 row with
a blank serial, and 794 had no corresponding SBE37 private row in this query.

Therefore a governed SBE37 public write uses its corresponding private
`seabird_sbe37` row as source-observation authority. A blank serial is retained
as provenance; only a missing source row is unresolved identity.

## Consequences for resolver policy

- **SeaFET v1:** automatic recovery remains justified only by the existing
  bounded rule. A 24-hour gap at `_IRL-LP_SEAFETV1` from 2026-08-15 04:00 to
  2026-08-16 03:00 was bracketed by `263` on both sides. Shorter gaps also had
  `0263`/`263` bracketing variants, which intentionally fail the current
  same-string requirement rather than silently normalizing a serial.
- **SBE37:** recent gaps can be long (the audit found runs of 461 and 238
  hourly rows) and some are bounded by different serials. No database-side
  interpolation is justified. Resolve from approved deployment/source evidence
  in writer integration or fail the governed public write closed.
- **SUNA v2 and Aquadopp:** their exact-source-row resolver remains correct for
  current data. Historical blank coverage means they must continue to fail
  closed at an active rejection rather than infer from adjacent observations.
- **ECO and CO2ProCV:** serial coverage does not remove their duplicate-source
  identity blocker. Their proposed manual adapters still need immutable upload
  provenance and deterministic source-row selection.

## Identity constraints observed

`(station,m_date)` is uniquely indexed on SBE37, SBE-ECO, SUNA v2, SeaFET v1,
and Aquadopp. It is not uniquely indexed on `seabird_eco` or
`prooceanus_co2procv`; those tables retain only their `row_id` unique key.
This supports the existing decision not to activate ECO or CO2ProCV governance
triggers.
