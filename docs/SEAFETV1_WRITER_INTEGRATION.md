# SeaFET v1 writer integration

## Current writer and write contract

The recurring writer is `seafet_ascii/R/seafet_ascii_process_recurring_final.R`.
It has no explicit DB transaction and currently writes public `SITE-WQ`
`ph_tempsal` rows before it constructs and upserts `_SITE_SEAFETV1` private
rows. The raw private payload preserves `serial_number_seafet` on insert and
on conflict update. It deliberately includes all raw observations, including
ones without a computed public pH value.

## Exact minimal patch plan — do not apply yet

Move the complete private dataset construction, existing-row comparison,
changed-row filtering, and private insert/update loops ahead of the public
loop. Keep the existing private de-duplication key `(station, m_date)`, station
mapping `_SITE_SEAFETV1` -> `SITE-WQ`, change detection, error-stop behavior,
and public payload unchanged. Only after all private writes succeed should the
current public `ph_tempsal` loop run. This is a reorder, not a rewrite or a
serial backfill. The SeaFET guard obtains identity from the private row and
uses its bounded two-sided resolver only for a temporary blank serial.

The writer was clean at audit time but was deliberately not edited. It sets
`application_name` to `seafet_ascii_process_recurring_final.R`, which matches
the known archive-trigger gate; staging must measure archive rows caused by
the reordered private updates. Add suppression-count reporting only after the
order change is proven on a clone.
