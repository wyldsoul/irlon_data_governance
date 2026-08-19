# Sea-Bird ECO suppression — proposed only

ECO source identity is `seabird_eco`, not the merged `seabird_sbeeco` public
row. The observed mapping is `_SITE_ECO` → `SITE-WQ`; source serial is
`serial_number_eco`. In the 2026-08-12 through 2026-08-19 sample, 1,176 source
rows produced 1,170 paired public rows; one source row lacked its ECO serial.

The real-time writer is `/home/irlon/irlon-data-services/php/loggernet2db.php`.
It obtains routing from `loggernet2db` and logically upserts by `(station,
m_date)`. The mapping proves ECO ownership of public `cdom`, `chl`,
`turbidity`, and `turbidity_bb3_470`/`532`/`650`, with their paired `qc_*`
columns. It separately ingests source `seabird_eco` rows, including
`serial_number_eco` from `ECOCoeff`.

Do not install an ECO trigger yet. A full read-only history check found 4,761
duplicate `(station,m_date)` source keys (up to three source rows per key).
That makes a timestamp-only serial resolver unsafe, especially because ECO
serials also change over deployments and can be temporarily absent. First
define an immutable source-row identity or a deterministic deduplication rule
for the real-time writer. The future module must key rejection to that proven
ECO source identity plus serial, never to the merged `seabird_sbeeco` row alone.

## Manual-upload path to design

The legacy candidate is
`sbe37_ascii/sql/kristen/Q_manualuploads_eco.sql`, followed by
`Q_manualuploads_sbeeco_eco_calculations.sql`. It averages manual source values
into hourly buckets, which is the correct observation grain. It is not a safe
governance adapter as written: it drops `serial_number_eco` before its hourly
grouping, uses a legacy source station spelling, and joins existing source rows
by `(station,m_date)` despite duplicate history.

The future manual adapter must require a station, serial, and upload manifest
identifier; group by all three plus the hourly bucket; select one explicit
source-row policy; write the private source row first; then write only the
ECO-owned public parameters. It must fail before a public write if its source
identity is not unique.
