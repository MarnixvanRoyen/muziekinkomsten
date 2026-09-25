-- =====================================================================
-- Muziekinkomsten — SoundCloud-cijfers (openbare plays/likes/reposts)
-- Vooraf: soundcloud_client_id en soundcloud_client_secret staan in de Vault.
-- Plak dit hele bestand in Supabase > SQL Editor en klik op "Run".
-- Veilig opnieuw te draaien.
-- =====================================================================

create extension if not exists http with schema extensions;

-- 1. Tabellen
create table if not exists public.sc_config (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  profile_url text not null,          -- bv. https://soundcloud.com/jouwnaam
  sc_user_id  text,                   -- wordt automatisch ingevuld
  updated_at  timestamptz not null default now()
);

create table if not exists public.sc_tracks (
  user_id       uuid not null references auth.users(id) on delete cascade,
  track_id      text not null,
  title         text not null default '',
  permalink_url text not null default '',
  created_at    timestamptz,
  duration_ms   bigint,
  first_seen    date not null default current_date,
  primary key (user_id, track_id)
);

create table if not exists public.sc_snapshots (
  user_id   uuid not null references auth.users(id) on delete cascade,
  track_id  text not null,
  snap_date date not null default current_date,
  plays     bigint,   -- leeg = SoundCloud geeft het getal niet (bv. verborgen)
  likes     bigint,
  reposts   bigint,
  comments  bigint,
  downloads bigint,
  primary key (user_id, track_id, snap_date)
);

-- 2. Beveiliging: alleen je eigen rijen LEZEN; schrijven doet alleen de database
do $$
declare t text;
begin
  foreach t in array array['sc_config','sc_tracks','sc_snapshots'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "eigen rijen lezen" on public.%I', t);
    execute format($p$create policy "eigen rijen lezen" on public.%I for select to authenticated
                     using (user_id = (select auth.uid()))$p$, t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- 3. Toegangsbewijs (token) ophalen met Client ID + Secret uit de Vault
create or replace function public.sc_token()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  cid  text;
  csec text;
  b64  text;
  r    extensions.http_response;
begin
  select decrypted_secret into cid  from vault.decrypted_secrets where name = 'soundcloud_client_id'     limit 1;
  select decrypted_secret into csec from vault.decrypted_secrets where name = 'soundcloud_client_secret' limit 1;
  if cid is null or csec is null then
    raise exception 'soundcloud_client_id of soundcloud_client_secret ontbreekt in de Vault';
  end if;
  b64 := replace(encode(convert_to(trim(cid) || ':' || trim(csec), 'UTF8'), 'base64'), E'\n', '');
  r := extensions.http((
         'POST', 'https://secure.soundcloud.com/oauth/token',
         array[extensions.http_header('Authorization', 'Basic ' || b64),
               extensions.http_header('accept', 'application/json; charset=utf-8')],
         'application/x-www-form-urlencoded', 'grant_type=client_credentials'
       )::extensions.http_request);
  if r.status <> 200 then
    raise exception 'SoundCloud token fout %: %', r.status, left(r.content, 300);
  end if;
  return r.content::jsonb->>'access_token';
end;
$$;

-- 4. Iets opvragen bij de SoundCloud API (volgt ook een doorverwijzing)
create or replace function public.sc_get(url text, tok text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r    extensions.http_response;
  loc  text;
  hops int := 0;
begin
  loop
    r := extensions.http((
           'GET', url,
           array[extensions.http_header('Authorization', 'OAuth ' || tok),
                 extensions.http_header('accept', 'application/json; charset=utf-8')],
           null, null
         )::extensions.http_request);
    exit when r.status not in (301, 302, 303, 307, 308) or hops >= 3;
    select h.value into loc from unnest(r.headers) h where lower(h.field) = 'location' limit 1;
    exit when loc is null;
    url := loc; hops := hops + 1;
  end loop;
  if r.status <> 200 then
    raise exception 'SoundCloud API fout % bij %: %', r.status, url, left(r.content, 300);
  end if;
  return r.content::jsonb;
end;
$$;

-- 5. Hoofdfunctie: al je openbare tracks + de cijfers van vandaag opslaan
create or replace function public.sc_refresh()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c      record;
  tok    text;
  j      jsonb;
  items  jsonb;
  uid    text;
  url    text;
  n      int := 0;
begin
  -- nachtelijke taak (niet ingelogd): iedereen; vanuit de app: alleen jezelf
  for c in select * from sc_config where auth.uid() is null or user_id = auth.uid() loop
    if tok is null then tok := sc_token(); end if;   -- één token per run

    -- a. profiel-URL omzetten naar SoundCloud-gebruikers-ID (eenmalig)
    uid := c.sc_user_id;
    if uid is null then
      j := sc_get('https://api.soundcloud.com/resolve?url=' || c.profile_url, tok);
      uid := coalesce(j->>'urn', j->>'id');
      update sc_config set sc_user_id = uid, updated_at = now() where user_id = c.user_id;
    end if;

    -- b. alle tracks ophalen, 200 per pagina
    url := 'https://api.soundcloud.com/users/' || uid || '/tracks?limit=200&linked_partitioning=true';
    while url is not null loop
      j := sc_get(url, tok);
      items := case when jsonb_typeof(j) = 'array' then j else coalesce(j->'collection', '[]') end;

      insert into sc_tracks (user_id, track_id, title, permalink_url, created_at, duration_ms)
      select c.user_id, coalesce(t->>'id', t->>'urn'), coalesce(t->>'title', ''),
             coalesce(t->>'permalink_url', ''),
             replace(t->>'created_at', '/', '-')::timestamptz,
             (t->>'duration')::bigint
        from jsonb_array_elements(items) t
      on conflict (user_id, track_id) do update
         set title = excluded.title, permalink_url = excluded.permalink_url,
             created_at = excluded.created_at, duration_ms = excluded.duration_ms;

      insert into sc_snapshots (user_id, track_id, snap_date, plays, likes, reposts, comments, downloads)
      select c.user_id, coalesce(t->>'id', t->>'urn'), current_date,
             (t->>'playback_count')::bigint,
             coalesce(t->>'favoritings_count', t->>'likes_count')::bigint,
             (t->>'reposts_count')::bigint,
             (t->>'comment_count')::bigint,
             (t->>'download_count')::bigint
        from jsonb_array_elements(items) t
      on conflict (user_id, track_id, snap_date) do update
         set plays = excluded.plays, likes = excluded.likes, reposts = excluded.reposts,
             comments = excluded.comments, downloads = excluded.downloads;

      n := n + jsonb_array_length(items);
      url := case when jsonb_typeof(j) = 'object' then j->>'next_href' end;
    end loop;
  end loop;

  return jsonb_build_object('tracks', n, 'soundcloud_user', uid);
end;
$$;

revoke execute on function public.sc_token()        from public, anon, authenticated;
revoke execute on function public.sc_get(text, text) from public, anon, authenticated;
revoke execute on function public.sc_refresh()       from public, anon;
grant  execute on function public.sc_refresh()       to authenticated;

-- 6. Jouw instelling: je SoundCloud-profiel  (CONTROLEER DEZE URL!)
insert into public.sc_config (user_id, profile_url)
select id, 'https://soundcloud.com/marreman'
  from auth.users
 where email = 'marnixvanroyen@gmail.com'
on conflict (user_id) do update
   set profile_url = excluded.profile_url, sc_user_id = null, updated_at = now();

-- 7. Elke nacht om 04:25 UTC automatisch ophalen (10 min na YouTube)
select cron.schedule('soundcloud-dagelijks', '25 4 * * *', 'select public.sc_refresh()');

-- 8. Test nu meteen: hier moet het aantal tracks en je SoundCloud-ID uitkomen
select public.sc_refresh();
