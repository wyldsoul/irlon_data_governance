# SeaFET v1 public-parameter suppression

The module governs only `ph_tempsal` on `SITE-WQ`; its source identity is the
corresponding `_SITE_SEAFETV1` row in `seabird_seafetv1`. It explicitly sets
only `ph_tempsal` to NULL and `qc_ph_tempsal` to the stored IRLON QARTOD flag.

The private replay trigger does nothing unless an exact active rejection exists.
It never changes raw/private columns. The public guard derives the source
identity from the matching source row and therefore prevents a rejected value
from being restored by a later public write.

`ph_tempsal` is the only supported SeaFET v1 governed public parameter. The
rejection API rejects every other name. Because direct registry edits can bypass
that API, both the public-write guard and private-replay apply function fail
closed when an applicable active SeaFET row has any unsupported parameter; they
never silently ignore malformed active registry data.

A SeaFET rejection with a `parent_rejection_id` is controlled by its active
parent. It cannot be independently reinstated while that parent remains active
— checking only the immediate parent is sufficient, since a row can never be
active while its own direct parent is active. Its parent is always an SBE37
`salinity` rejection (`ph_tempsal` requires both `temperature_water` and
`salinity`, per `seafet_ascii/R/seafet_ascii_process_recurring_final.R`); when
that `salinity` rejection is itself derived from an SBE37 `temperature_water`
rejection, reinstating temperature releases the entire chain in one call,
including this SeaFET child, via the SBE37 module's recursive reinstatement.
A later normal replay restores the measurement; restoration of the QC rollup
remains a separate QARTOD process.

Serial resolver: exact nonblank `serial_number_seafet`; otherwise nearest
nonblank rows before and after the timestamp, each within 24 hours and equal.
Any disagreement or missing side fails closed. This 24-hour bound is based on
the longest observed temporary gap in the audited week.
