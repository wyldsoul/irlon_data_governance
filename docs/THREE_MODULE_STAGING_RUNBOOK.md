# SeaFET, SUNA, and Aquadopp trigger staging runbook

This runbook is for a restored-production clone or dedicated staging database.
It is not authorization to change production.

## Preconditions

1. Load the generic registry, then the relevant module SQL:
   `sql/seafetv1/public_parameter_suppression.sql`,
   `sql/sunav2/public_parameter_suppression.sql`, or
   `sql/aquadopp/public_parameter_suppression.sql`.
2. Capture existing table, function, trigger, and archive-trigger DDL.
3. Run the current writers against the clone only. SUNA may be tested as-is.
   SeaFET and Aquadopp require their separately approved private-first patches
   before their guards are enabled.
4. Seed one active rejection per owned parameter and one similar non-rejected
   source observation.

## Required staging outcomes

- A normal source/public update with no active rejection produces no extra
  public update from the replay trigger.
- A rejected parameter is NULL with its stored QARTOD flag; another parameter
  at the same timestamp remains unchanged.
- Replaying the exact private row cannot restore the public parameter.
- A fabricated serial or wrong source station cannot activate a rejection.
- Reinstatement permits the next normal public write.
- SUNA's existing private-first autocommit writes work because its guard reads
  the committed private row; verify that an unrelated later public write is
  unaffected.
- SeaFET and Aquadopp public guards are not enabled until their private-first
  reorder is staged and approved, including their manual/legacy bypass review.

## Deployment hold points

Do not proceed beyond staging until archive effects are reviewed. SeaFET and
Aquadopp existing recurring writers are public-first; their writer ordering
must be changed in a separately approved change before their production
triggers are installed. No transaction-local identity context is needed for
these modules because their guards resolve identity from the matching private
row; this is why private-first ordering is mandatory. SeaFET and Aquadopp
archive triggers are gated by the same application names their recurring
writers set, so clone testing must capture archive counts before and after the
reorder. Confirm the SUNA archive gate separately because its current writer
uses `suna_ascii_tscorrection_recurring_final.R`.
