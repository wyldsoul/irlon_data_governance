# Sea-Bird ECO writer integration — production validation required

The real-time writer is `/home/irlon/irlon-data-services/php/loggernet2db.php`,
run from the `irlon` service account's scheduler. It uses `loggernet2db` rows
rather than hard-coded table names. ECO source feeds write to `seabird_eco`;
`ECOCalculations` and `ECOBB3Calculations` write the public `seabird_sbeeco`
parameters. Its logical upsert check is `(station,m_date)`.

Before trigger activation, add a non-production adapter that verifies/recovers
the required source serial before the public calculation row is written. The
source table's missing enforced unique key remains a production validation item.

For a future manual upload, use the legacy Kristen Q files only as a calculation
reference; do not execute them as the governance path without the explicit
serial and manifest identity requirements in `ECO_PUBLIC_PARAMETER_SUPPRESSION.md`.
