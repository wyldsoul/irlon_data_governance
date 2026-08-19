# SUNA v2 public-parameter suppression

SUNA owns public `nitrate_um` and `nitrate_mgl`, with `qc_nitrate_um` and
`qc_nitrate_mgl`. Its source row is `_SITE_SUNA` and public row is `SITE-WQ` in
`seabird_sunav2`; `serial_number_suna` must exist on that exact source row.

Both public guard and private replay trigger use fixed SQL branches for those
two parameters only. Private/source data is never NULLed or deleted.
