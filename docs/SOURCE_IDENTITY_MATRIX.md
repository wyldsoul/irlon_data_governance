# Source identity matrix

Read-only production audit: 2026-08-12 through 2026-08-19, with
`default_transaction_read_only = on`.

| Instrument family | Source / public table | Source → public station | Serial / resolution | Owned public parameters and QC | Source / public key | Public serial | Replay / guard | Status / open question |
|---|---|---|---|---|---|---|---|---|
| SBE37 | `seabird_sbe37` → `seabird_sbeeco` | `_SITE_SBE37` → `SITE-WQ` | `serial_number_sbe37`; source-specific handling | SBE37 fixed parameter list | `(station,m_date)` / `(station,m_date)` | No | both | implemented + tested |
| Sea-Bird ECO | `seabird_eco` → `seabird_sbeeco` | `_SITE_ECO` → `SITE-WQ` | `serial_number_eco`; temporary gaps and serial transitions exist | `cdom`, `chl`, `turbidity`, `turbidity_bb3_470/532/650` / matching `qc_*` | 4,761 historical duplicate source `(station,m_date)` keys / `(station,m_date)` public key | No | blocked | writer proven: `loggernet2db.php`; define immutable source-row identity or deterministic deduplication first |
| SeaFET v1 | `seabird_seafetv1` (private/public station partitions) | `_SITE_SEAFETV1` → `SITE-WQ` | `serial_number_seafet`; exact value, otherwise agreeing nearest serials on both sides within 24 h | `ph_tempsal` / `qc_ph_tempsal` | `(station,m_date)` / `(station,m_date)` | No | both | implemented in disposable test; recurring writer is public-first and needs approved reorder plus archive validation |
| SUNA v2 | `seabird_sunav2` (private/public station partitions) | `_SITE_SUNA` → `SITE-WQ` | `serial_number_suna`; exact source row required | `nitrate_um`, `nitrate_mgl` / matching `qc_*` | `(station,m_date)` / `(station,m_date)` | No | both | implemented in disposable test; current recurring writer is private-first/autocommit-compatible; staging archive and legacy-path validation required |
| Nortek Aquadopp | `nortek_aquadopp` (private/public station partitions) | `_SITE_AQUADOPP` → `SITE-WQ` | `serial_number_aquadopp`; exact source row required | `current_speed`, `current_direction` / matching `qc_*` | `(station,m_date)` / `(station,m_date)` | No | both | implemented in disposable test; recurring and manual R writers are public-first and need approved reorder; legacy manual SQL remains unvalidated |
| Pro-Oceanus CO2ProCV | `prooceanus_co2procv` (private/public station partitions) | `_SITE_CO2PROCV` → `SITE-WQ` | `serial_number_co2procv`; exact source rows present in the sampled week | `co2_ppm` / `qc_co2_ppm` | 12 historical duplicate `(station,m_date)` keys; only `row_id` is constrained | No | blocked | writer proven: real-time `loggernet2db.php`; define immutable source-row identity or deterministic deduplication first |

Rejection identity belongs to the **source parameter**, not the public row.
For the shared-table families, the underscore-prefixed row is the raw/source
identity and the `-WQ` row is its derived public target.

The sample contained 24 consecutive SeaFET private rows without a serial at
`_IRL-LP_SEAFETV1`; known serial `263` immediately surrounded the gap. The
module therefore permits only two-sided, same-serial interpolation inside a
24-hour window. It never writes that inferred serial back to the raw row.

CO2ProCV had no sampled serial gaps and no sampled duplicate timestamps, but
absence of an enforced `(station,m_date)` constraint is not sufficient proof
for safe trigger enforcement.
