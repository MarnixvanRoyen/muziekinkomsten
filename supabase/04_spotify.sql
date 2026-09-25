-- =====================================================================
-- Muziekinkomsten — Spotify for Artists (CSV-export "Songs", periode "All time")
-- Elke import = een momentopname (stand op die dag). Zo zie je later
-- ook hoeveel streams er tussen twee imports bij zijn gekomen.
-- Veilig opnieuw te draaien.
-- =====================================================================
create table if not exists public.sp_snapshots (
  id           bigint generated always as identity primary key,
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  snap_date    date not null,                 -- dag van de import
  song         text not null,
  release_date date,
  streams      numeric not null default 0,    -- totaal sinds release
  listeners    numeric,
  saves        numeric,
  source_file  text,
  imported_at  timestamptz not null default now(),
  unique (user_id, snap_date, song)
);

alter table public.sp_snapshots enable row level security;
drop policy if exists "eigen rijen" on public.sp_snapshots;
create policy "eigen rijen" on public.sp_snapshots for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.sp_snapshots from anon;
grant select, insert, update, delete on public.sp_snapshots to authenticated;

-- Import: vervangt de momentopname van dezelfde dag (dus twee keer inladen = geen dubbele rijen)
create or replace function public.import_spotify(rows jsonb, snap date, file_name text default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  n_del int;
  n_ins int;
begin
  if auth.uid() is null then
    raise exception 'Niet ingelogd';
  end if;

  delete from sp_snapshots where user_id = auth.uid() and snap_date = snap;
  get diagnostics n_del = row_count;

  -- zelfde titel twee keer in het bestand? dan samen optellen
  insert into sp_snapshots (user_id, snap_date, song, release_date, streams, listeners, saves, source_file)
  select auth.uid(), snap, x.song, min(x.release_date), sum(coalesce(x.streams,0)), sum(x.listeners), sum(x.saves), file_name
    from jsonb_to_recordset(rows) as x(song text, release_date date, streams numeric, listeners numeric, saves numeric)
   where coalesce(x.song,'') <> ''
   group by x.song;
  get diagnostics n_ins = row_count;

  return jsonb_build_object('deleted', n_del, 'inserted', n_ins);
end;
$$;

revoke execute on function public.import_spotify(jsonb, date, text) from public, anon;
grant execute on function public.import_spotify(jsonb, date, text) to authenticated;
