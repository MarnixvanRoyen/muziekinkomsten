-- =====================================================================
-- Muziekinkomsten — YouTube-cijfers (openbare views/likes/reacties)
-- Plak dit hele bestand in Supabase > SQL Editor en klik op "Run".
-- Veilig opnieuw te draaien.
-- =====================================================================

-- 1. Extensie om vanuit de database websites/API's aan te roepen
create extension if not exists http with schema extensions;

-- 2. Tabellen
create table if not exists public.yt_config (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  seed_video_id text not null,                 -- één track van je Topic-kanaal
  channel_ids   text[] not null default '{}',  -- extra kanalen (je eigen uploads)
  updated_at    timestamptz not null default now()
);

create table if not exists public.yt_videos (
  user_id      uuid not null references auth.users(id) on delete cascade,
  video_id     text not null,
  title        text not null default '',
  channel_id   text not null default '',
  published_at timestamptz,
  first_seen   date not null default current_date,
  primary key (user_id, video_id)
);

create table if not exists public.yt_snapshots (
  user_id   uuid not null references auth.users(id) on delete cascade,
  video_id  text not null,
  snap_date date not null default current_date,
  views     bigint not null default 0,
  likes     bigint not null default 0,
  comments  bigint not null default 0,
  primary key (user_id, video_id, snap_date)
);

-- 3. Beveiliging: jij mag alleen je eigen rijen LEZEN. Schrijven doet alleen de database zelf.
do $$
declare t text;
begin
  foreach t in array array['yt_config','yt_videos','yt_snapshots'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "eigen rijen lezen" on public.%I', t);
    execute format($p$create policy "eigen rijen lezen" on public.%I for select to authenticated
                     using (user_id = (select auth.uid()))$p$, t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- 4. Hulpfunctie: vraag iets op bij de YouTube Data API (sleutel komt uit de Vault)
create or replace function public.yt_get(path text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  k text;
  r extensions.http_response;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'youtube_api_key' limit 1;
  if k is null then
    raise exception 'Geen youtube_api_key gevonden in de Vault';
  end if;
  r := extensions.http_get('https://www.googleapis.com/youtube/v3/' || path || '&key=' || k);
  if r.status <> 200 then
    raise exception 'YouTube API fout %: %', r.status, left(r.content, 300);
  end if;
  return r.content::jsonb;
end;
$$;

-- 5. Hoofdfunctie: zoek al je tracks en sla de cijfers van vandaag op
create or replace function public.yt_refresh()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c       record;
  j       jsonb;
  topic   text;
  ch      text;
  chans   text[];
  tok     text;
  ids     text[];
  batch   text[];
  i       int;
  n_vid   int := 0;
  fouten  text[] := '{}';
begin
  -- nachtelijke taak (niet ingelogd): iedereen in yt_config; vanuit de app: alleen jezelf
  for c in select * from yt_config where auth.uid() is null or user_id = auth.uid() loop
    -- a. via de voorbeeld-track het Topic-kanaal vinden
    j := yt_get('videos?part=snippet&id=' || c.seed_video_id);
    topic := j->'items'->0->'snippet'->>'channelId';
    chans := array_remove(array_append(c.channel_ids, topic), null);
    ids   := array[c.seed_video_id];

    -- b. per kanaal de uploads-lijst doorlopen (kanaal-ID UC... -> lijst UU...)
    foreach ch in array chans loop
      begin
        tok := null;
        loop
          j := yt_get('playlistItems?part=contentDetails&maxResults=50&playlistId=UU' || substr(ch, 3)
                      || coalesce('&pageToken=' || tok, ''));
          ids := ids || array(select x->'contentDetails'->>'videoId' from jsonb_array_elements(j->'items') x);
          tok := j->>'nextPageToken';
          exit when tok is null;
        end loop;
      exception when others then
        fouten := fouten || (ch || ': ' || sqlerrm);
      end;
    end loop;

    ids := array(select distinct unnest(ids));

    -- c. cijfers ophalen, per 50 tegelijk
    i := 1;
    while i <= coalesce(array_length(ids, 1), 0) loop
      batch := ids[i:i+49];
      j := yt_get('videos?part=snippet,statistics&id=' || array_to_string(batch, ','));

      insert into yt_videos (user_id, video_id, title, channel_id, published_at)
      select c.user_id, v->>'id', v->'snippet'->>'title', v->'snippet'->>'channelId',
             (v->'snippet'->>'publishedAt')::timestamptz
        from jsonb_array_elements(j->'items') v
      on conflict (user_id, video_id) do update
         set title = excluded.title, channel_id = excluded.channel_id, published_at = excluded.published_at;

      insert into yt_snapshots (user_id, video_id, snap_date, views, likes, comments)
      select c.user_id, v->>'id', current_date,
             coalesce((v->'statistics'->>'viewCount')::bigint, 0),
             coalesce((v->'statistics'->>'likeCount')::bigint, 0),
             coalesce((v->'statistics'->>'commentCount')::bigint, 0)
        from jsonb_array_elements(j->'items') v
      on conflict (user_id, video_id, snap_date) do update
         set views = excluded.views, likes = excluded.likes, comments = excluded.comments;

      n_vid := n_vid + jsonb_array_length(j->'items');
      i := i + 50;
    end loop;
  end loop;

  return jsonb_build_object('videos', n_vid, 'topic_kanaal', topic, 'fouten', fouten);
end;
$$;

revoke execute on function public.yt_get(text) from public, anon, authenticated;
revoke execute on function public.yt_refresh() from public, anon;
grant  execute on function public.yt_refresh() to authenticated;

-- 6. Jouw instellingen: startpunt Deep Summer Soul + je eigen kanaal
insert into public.yt_config (user_id, seed_video_id, channel_ids)
select id, 'Sz-pJTx0268', array['UCu6P7Gmb_julZi6dmgdZqFQ']
  from auth.users
 where email = 'marnixvanroyen@gmail.com'
on conflict (user_id) do update
   set seed_video_id = excluded.seed_video_id, channel_ids = excluded.channel_ids, updated_at = now();

-- Controle: hier moet 1 regel uitkomen
select user_id, seed_video_id, channel_ids from public.yt_config;
