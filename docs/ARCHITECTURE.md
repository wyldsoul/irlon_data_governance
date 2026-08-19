# Rejection-registry architecture

IRLON uses one central `rejected_observations` registry for deliberate,
parameter-level suppression of values in governed public tables.

```text
generic rejected_observations registry
             |
             +-- SBE37 identity + station mapping + guards/triggers  (implemented pilot)
             +-- SeaFET identity + station mapping + guards/triggers (future)
             +-- other instrument-specific enforcement modules       (future)
```

The registry records a rejection decision, not a raw-data deletion. Its generic
identity includes source/public tables and stations, instrument type, instrument
serial, timestamp, and public parameter. The serial is required: an observation
whose source row temporarily omits it must be resolved from an approved source
or deployment history, or fail closed. A module validates that
identity against its actual source schema and decides how to keep the affected
public parameter NULL on replay.

No generic dynamic trigger mutates arbitrary table columns. Public-parameter
validation and NULL/QC mutation remain explicit in each instrument/table module.

`qc_flag` stores the QARTOD rollup to place on the affected public parameter:
`1 = bad`, `2 = suspect`, `3 = good`. The registry stores the applicable
IRLON QARTOD rollup; it does not define a separate rejection-specific QC
vocabulary.
