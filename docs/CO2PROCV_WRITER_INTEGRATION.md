# CO2ProCV writer integration — production validation required

The active real-time writer is `/home/irlon/irlon-data-services/php/loggernet2db.php`,
run by the `irlon` service account. It uses `loggernet2db` configuration:
`CO2ProCVData` writes private `_SITE_CO2PROCV` fields including
`serial_number_co2procv`; `CO2_ppmv` writes public `SITE-WQ.co2_ppm`.

The script does not use PostgreSQL `ON CONFLICT`; it attempts an insert after a
`(station,m_date)` count check, then issues an update when a row exists. That
logical key must be validated in staging before a suppression trigger is
enabled.

The legacy manual reference is
`sbe37_ascii/sql/kristen/Q_manualuploads_co2procv.sql`; it must be replaced by
a manifest-aware, private-first adapter before governance enforcement is used.
