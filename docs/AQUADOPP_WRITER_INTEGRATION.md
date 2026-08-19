# Aquadopp writer integration

## Current writers and write contract

The recurring writer is `aquadopp_ascii/R/aquadopp_ascii_process_recurring_final.R`;
the manual R counterpart is `manualdep_aquadopp_ascii_process.R`. Both use
individual database statements without an explicit transaction, source
`serial_number_aquadopp` from `Aquadopp_Sn`, preserve it in private inserts and
conflict updates, and currently write public `SITE-WQ` current speed/direction
before `_SITE_AQUADOPP` private rows. Both therefore need the same ordering
correction. Legacy SQL files such as `sql/Q_manualuploads_aquadopp.sql` also
write the shared table and require a separate governance review before trigger
activation; they are not covered by this module-ready writer path.

## Exact minimal patch plan — do not apply yet

After building `public` and `private`, perform the existing station conversion
to `_SITE_AQUADOPP` and execute the private loop first. Preserve its current
`(station, m_date)` upsert and all payload columns. Abort on a private failure;
only then execute the unchanged public loop. Do not add session identity
settings: the guard resolves the serial from the matching private row. Apply
the same reorder to the manual R counterpart only in a separately approved
manual-upload integration change.

The recurring writer's application name matches the known archive-trigger gate
(`aquadopp_ascii_process_recurring_final.R`), so a staging clone must measure
archive effects of private-first updates. No Aquadopp writer files were edited.
