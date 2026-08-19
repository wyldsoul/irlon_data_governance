# SeaFET v1 public-parameter suppression

The module governs only `ph_tempsal` on `SITE-WQ`; its source identity is the
corresponding `_SITE_SEAFETV1` row in `seabird_seafetv1`. It explicitly sets
only `ph_tempsal` to NULL and `qc_ph_tempsal` to the stored IRLON QARTOD flag.

The private replay trigger does nothing unless an exact active rejection exists.
It never changes raw/private columns. The public guard derives the source
identity from the matching source row and therefore prevents a rejected value
from being restored by a later public write.

Serial resolver: exact nonblank `serial_number_seafet`; otherwise nearest
nonblank rows before and after the timestamp, each within 24 hours and equal.
Any disagreement or missing side fails closed. This 24-hour bound is based on
the longest observed temporary gap in the audited week.
