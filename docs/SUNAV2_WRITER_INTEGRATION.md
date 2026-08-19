# SUNA v2 writer integration

## Current writer and write contract

The recurring writer is
`suna_ascii/R/suna_ascii_tscorrection_recurring_final.R`. It is clean at the
audited revision and uses individual DBI statements without an explicit
transaction. It groups by `m_date`, station, and `serial_number_suna`, then:

1. upserts `_SITE_SUNA` private rows first, including
   `serial_number_suna` in both `INSERT` and conflict-update paths;
2. upserts `SITE-WQ` public `nitrate_um` and `nitrate_mgl` second.

The private mapping is `_SITE_SUNA` -> `SITE-WQ`. The SUNA guard derives the
serial by looking up that committed private row; it uses no transaction-local
setting or other session identity context. Consequently the writer's existing
private-first autocommit pattern is compatible with the module.

## Minimum integration change

No writer change is required for enforcement correctness. Do not add a GUC,
and do not wrap an identity-setting statement separately from the public
upsert: the module needs neither. If operator reporting is desired, call
`sunav2_count_active_rejections(source_station, serial_number_suna, m_date)`
after the private upsert and add its result to the existing email/log summary
as: `N rejected public parameter values suppressed`. Reporting must not alter
the public write or enforcement outcome.

## Staging requirements and risks

On a restored-production clone, verify private-first replay, active rejection,
reinstatement, a blank/ambiguous source serial, and the archive-trigger
behavior. The production archive trigger's application-name condition must be
verified: this writer sets `suna_ascii_tscorrection_recurring_final.R`, while
the historic SUNA archive condition may use a different name. Legacy
`suna_ascii_tscorrection_recurring.R` and TAO repair scripts are separate
write paths and are not approved for trigger activation until audited.

No SUNA writer file was edited in this task.
