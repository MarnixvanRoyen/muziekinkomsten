-- =====================================================================
-- Muziekinkomsten — database-opzet voor Supabase
-- Plak dit hele bestand in Supabase > SQL Editor en klik op "Run".
-- Je kunt het veilig opnieuw draaien: bestaande tabellen blijven staan.
-- =====================================================================

-- 1. SoundCloud-regels (één regel uit het earnings report = één rij)
create table if not exists public.sc_earnings (
  id                bigint generated always as identity primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reporting_period  date not null,          -- maand waarin geluisterd is
  accounting_period date not null,          -- maand waarin SoundCloud het afrekende
  artist            text not null default '',
  release           text not null default '',
  track             text not null default '',
  upc               text not null default '',
  isrc              text not null default '',
  partner           text not null default '',   -- SOUNDCLOUD, FACEBOOK, APPLE, ...
  country           text not null default '',   -- landcode, bijv. NL
  type              text not null default '',   -- SUB_STREAM, AD_STREAM, ...
  units             numeric not null default 0,
  revenue_usd       numeric not null default 0,
  revenue_share     numeric,
  split_share       numeric,
  source_file       text,
  imported_at       timestamptz not null default now()
);
create index if not exists sc_earnings_user_period on public.sc_earnings (user_id, accounting_period);

-- 2. Label (DJ·World): afrekeningen per periode
create table if not exists public.label_periods (
  id           bigint generated always as identity primary key,
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  period_month date not null,     -- eerste dag van de afrekenmaand
  name         text not null,     -- naam zoals op het overzicht
  gross        numeric not null default 0,
  aggregator   numeric not null default 0,   -- negatief bedrag
  djworld      numeric not null default 0,   -- negatief bedrag
  net          numeric not null default 0,
  status       text not null default '',
  unique (user_id, name)
);

-- 3. Label: totalen per nummer (stand van het laatste overzicht)
create table if not exists public.label_tracks (
  id        bigint generated always as identity primary key,
  user_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  track     text not null,
  version   text not null default '',
  artist    text not null default '',
  streams   numeric not null default 0,
  downloads numeric not null default 0,
  gross     numeric not null default 0,
  net       numeric not null default 0,
  unique (user_id, track, version)
);
-- nieuw format (sinds 25-09-2026): aantallen streams en downloads per nummer
alter table public.label_tracks add column if not exists stream_count   numeric not null default 0;
alter table public.label_tracks add column if not exists download_count numeric not null default 0;

-- 4. Label: saldo-overzicht per keer dat je een totaaloverzicht krijgt
create table if not exists public.label_statements (
  id             bigint generated always as identity primary key,
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  statement_date date not null,
  gross          numeric not null default 0,
  net            numeric not null default 0,
  paid_out       numeric not null default 0,
  open_balance   numeric not null default 0,
  to_book        numeric not null default 0,
  in_process     numeric not null default 0,
  outside_tool   numeric not null default 0,
  unique (user_id, statement_date)
);

-- =====================================================================
-- Beveiliging: Row Level Security (RLS)
-- Iedere ingelogde gebruiker ziet en wijzigt ALLEEN zijn eigen rijen.
-- Niet ingelogd = niks.
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['sc_earnings','label_periods','label_tracks','label_statements'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "eigen rijen" on public.%I', t);
    execute format($p$create policy "eigen rijen" on public.%I for all to authenticated
                     using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))$p$, t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- =====================================================================
-- Import van een SoundCloud-CSV (wordt aangeroepen door de app)
-- Vervangt alle regels van de afrekenperiodes die in het bestand staan.
-- Zo krijg je nooit dubbele regels, ook niet als je hetzelfde
-- lifetime-rapport later opnieuw inlaadt.
-- =====================================================================
create or replace function public.import_soundcloud(rows jsonb, file_name text default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  periods date[];
  n_del int;
  n_ins int;
begin
  if auth.uid() is null then
    raise exception 'Niet ingelogd';
  end if;

  select array_agg(distinct (r->>'accounting_period')::date)
    into periods
    from jsonb_array_elements(rows) r;

  delete from sc_earnings
   where user_id = auth.uid()
     and accounting_period = any(periods);
  get diagnostics n_del = row_count;

  insert into sc_earnings (user_id, reporting_period, accounting_period, artist, release, track, upc, isrc,
                           partner, country, type, units, revenue_usd, revenue_share, split_share, source_file)
  select auth.uid(), x.reporting_period, x.accounting_period,
         coalesce(x.artist,''), coalesce(x.release,''), coalesce(x.track,''), coalesce(x.upc,''), coalesce(x.isrc,''),
         coalesce(x.partner,''), coalesce(x.country,''), coalesce(x.type,''),
         coalesce(x.units,0), coalesce(x.revenue_usd,0), x.revenue_share, x.split_share, file_name
    from jsonb_to_recordset(rows) as x(
         reporting_period date, accounting_period date, artist text, release text, track text, upc text,
         isrc text, partner text, country text, type text, units numeric, revenue_usd numeric,
         revenue_share numeric, split_share numeric);
  get diagnostics n_ins = row_count;

  return jsonb_build_object('deleted', n_del, 'inserted', n_ins, 'periods', coalesce(array_length(periods,1),0));
end;
$$;

revoke execute on function public.import_soundcloud(jsonb, text) from public, anon;
grant execute on function public.import_soundcloud(jsonb, text) to authenticated;

-- =====================================================================
-- Import van een DJ·World totaaloverzicht (PDF, gelezen door de app)
-- Een totaaloverzicht bevat "alles vanaf het begin", dus de periodes en
-- nummers worden in zijn geheel vervangen door de nieuwste stand.
-- =====================================================================
create or replace function public.import_djworld(doc jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  n_p int;
  n_t int;
  s jsonb := doc->'summary';
begin
  if auth.uid() is null then
    raise exception 'Niet ingelogd';
  end if;
  if jsonb_array_length(coalesce(doc->'periods','[]')) = 0 or jsonb_array_length(coalesce(doc->'tracks','[]')) = 0 then
    raise exception 'Geen periodes of nummers in dit overzicht';
  end if;

  delete from label_periods where user_id = auth.uid();
  delete from label_tracks  where user_id = auth.uid();

  insert into label_periods (user_id, period_month, name, gross, aggregator, djworld, net, status)
  select auth.uid(), coalesce(x.period_month, date_trunc('month', now())::date), x.name,
         coalesce(x.gross,0), coalesce(x.aggregator,0), coalesce(x.djworld,0), coalesce(x.net,0), coalesce(x.status,'')
    from jsonb_to_recordset(doc->'periods') as x(period_month date, name text, gross numeric, aggregator numeric,
                                                  djworld numeric, net numeric, status text);
  get diagnostics n_p = row_count;

  insert into label_tracks (user_id, track, version, artist, stream_count, download_count, streams, downloads, gross, net)
  select auth.uid(), x.track, coalesce(x.version,''), coalesce(x.artist,''),
         coalesce(x.stream_count,0), coalesce(x.download_count,0),
         coalesce(x.streams,0), coalesce(x.downloads,0), coalesce(x.gross,0), coalesce(x.net,0)
    from jsonb_to_recordset(doc->'tracks') as x(track text, version text, artist text, stream_count numeric,
                                                 download_count numeric, streams numeric, downloads numeric,
                                                 gross numeric, net numeric);
  get diagnostics n_t = row_count;

  insert into label_statements (user_id, statement_date, gross, net, paid_out, open_balance, to_book, in_process, outside_tool)
  values (auth.uid(), (doc->>'statement_date')::date,
          coalesce((s->>'gross')::numeric,0), coalesce((s->>'net')::numeric,0), coalesce((s->>'paid_out')::numeric,0),
          coalesce((s->>'open_balance')::numeric,0), coalesce((s->>'to_book')::numeric,0),
          coalesce((s->>'in_process')::numeric,0), coalesce((s->>'outside_tool')::numeric,0))
  on conflict (user_id, statement_date) do update
     set gross = excluded.gross, net = excluded.net, paid_out = excluded.paid_out,
         open_balance = excluded.open_balance, to_book = excluded.to_book,
         in_process = excluded.in_process, outside_tool = excluded.outside_tool;

  return jsonb_build_object('periods', n_p, 'tracks', n_t);
end;
$$;

revoke execute on function public.import_djworld(jsonb) from public, anon;
grant execute on function public.import_djworld(jsonb) to authenticated;
