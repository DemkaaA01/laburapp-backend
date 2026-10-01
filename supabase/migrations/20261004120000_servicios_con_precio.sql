-- Los servicios publicados por trabajadores tienen que tener precio de
-- referencia ("Desde $X por m²"). Al cliente no se le pide precio al publicar.
-- NOT VALID: no frena los servicios viejos sin precio, pero sí los nuevos y
-- cualquier cambio (al editarlos, hay que ponerle precio).
alter table public.servicios
  add constraint servicios_con_precio check (precio_desde is not null and precio_unidad is not null) not valid;
