# Rejection-registry architecture

IRLON uses one central `rejected_observations` registry for deliberate,
parameter-level suppression of values in governed public tables.

```text
generic rejected_observations registry
             |
             +-- SBE37 identity + station mapping + guards/triggers  (implemented pilot)
             +-- SeaFET v1 / Aquadopp modules                        (disposable-test implementation)
             +-- SUNA v2 module                                      (realistic disposable PG12 simulation)
             +-- ECO / CO2ProCV modules                              (proposed; production validation required)
             +-- other instrument-specific enforcement modules       (future)
```

The registry records a rejection decision, not a raw-data deletion. Its generic
identity includes source/public tables and stations, instrument type, timestamp,
and public parameter. Implemented modules record the immutable source pair
`(source_table,source_row_id)`; station and timestamp remain the source/public
mapping and replay context. Where a source table has a unique `(station,m_date)`
key and only one instrument of that type is deployed at a station at a time,
that mapping is deterministic; serial is nullable provenance. A module
validates the source observation and decides how to keep the affected public
parameter NULL on replay. Serial is provenance unless required to disambiguate
multiple source observations.

## Derived parameters

An active rejection can have auditable child decisions through
`parent_rejection_id`. The first implemented rule is SBE37
`temperature_water` → SBE37 `salinity` and `dissolved_oxygen`; when a matched
private SeaFET observation exists at the same public station/time, it also
creates SeaFET `ph_tempsal`. Children retain their own source table/row ID and
receive the parent QARTOD flag. No SeaFET observation means no SeaFET child and
does not block the SBE37 parent. Reinstating the parent deactivates only its
linked children; it never reconstructs historical public values.

No generic dynamic trigger mutates arbitrary table columns. Public-parameter
validation and NULL/QC mutation remain explicit in each instrument/table module.

`qc_flag` stores the QARTOD rollup to place on the affected public parameter:
`1 = bad`, `2 = suspect`, `3 = good`. The registry stores the applicable
IRLON QARTOD rollup; it does not define a separate rejection-specific QC
vocabulary.

For shared physical tables, source identity belongs to the underscore-prefixed
instrument row and the rejected source parameter—not simply to the `-WQ`
public row. Every module uses an explicit fixed parameter list; no generic
trigger performs dynamic arbitrary-column mutation.
