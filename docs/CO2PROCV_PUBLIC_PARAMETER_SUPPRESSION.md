# Pro-Oceanus CO2ProCV suppression — proposed only

Read-only audit verified `_SITE_CO2PROCV` → `SITE-WQ` pairing and exact sampled
`serial_number_co2procv` values. The active real-time writer is
`/home/irlon/irlon-data-services/php/loggernet2db.php`; its `loggernet2db`
configuration maps `CO2ProCVData` source columns to the private station and
maps `CO2_ppmv` to public `co2_ppm`. The writer logically upserts by
`(station,m_date)`, although the production table does not enforce that key.

Do not install a trigger or create executable enforcement SQL yet. A full
read-only history check found 12 duplicate `(station,m_date)` keys (up to three
rows per key), so the writer's logical key is not a sufficient governance
identity. Before implementation, define an immutable source-row identity or a
deterministic deduplication rule and verify source-serial ordering before the
public `co2_ppm` write. This preserves the rule that a rejection must attach to
a proven source parameter, not merely a public timestamp.

## Manual-upload path to design

The legacy candidate is
`sbe37_ascii/sql/kristen/Q_manualuploads_co2procv.sql`. It correctly groups
the staged raw values by hourly bucket, station, and
`serial_number_co2procv`, then produces a private `_SITE_CO2PROCV` row and a
public `SITE-WQ.co2_ppm` row. It is still not a safe governance adapter: its
join back to `prooceanus_co2procv` is only `(station,m_date)`, and the history
contains duplicate keys.

The future adapter must retain a manual-upload manifest identifier, choose one
explicit source-row replacement policy, write/validate the private serial row
first, and only then write public `co2_ppm`. If the candidate source identity
matches zero or more than one existing row, it must fail closed rather than
choose a row implicitly.
