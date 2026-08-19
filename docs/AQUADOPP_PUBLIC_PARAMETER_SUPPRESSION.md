# Nortek Aquadopp public-parameter suppression

Aquadopp owns `current_speed` and `current_direction` on `SITE-WQ`, paired with
their `qc_*` columns. The source row is `_SITE_AQUADOPP` in the same table and
must supply `serial_number_aquadopp` at the exact timestamp.

The module's fixed parameter handling prevents arbitrary registry text from
changing another column. Its guard and replay trigger return immediately when
no indexed active rejection exists; raw/private values are unchanged.
