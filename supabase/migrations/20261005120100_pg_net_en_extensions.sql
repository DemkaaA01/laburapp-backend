-- pg_net quedó registrado en el schema public; Supabase recomienda que las
-- extensiones vivan en "extensions". Las funciones siguen en el schema net
-- (net.http_post), así que no cambia nada para enviar_push().
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_net' and extnamespace = 'public'::regnamespace) then
    drop extension pg_net;
    create extension pg_net with schema extensions;
  end if;
end
$$;
