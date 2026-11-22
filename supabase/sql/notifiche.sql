-- =====================================================================
-- NOTIFICHE PUSH (arrivano anche ad app chiusa)
-- Da eseguire DOPO aver creato la Edge Function "avvisi" su Supabase.
--
-- PRIMA DI PREMERE RUN: sostituisci INCOLLA_QUI_IL_SEGRETO (riga sotto)
-- con lo stesso testo che hai messo nel segreto CASA_SECRET della funzione.
-- Si può rieseguire senza danni.
-- =====================================================================

create extension if not exists pg_net   with schema extensions;
create extension if not exists pg_cron;

-- ---------- 1. Dove si salvano i telefoni iscritti ----------
create table if not exists public.push_subs (
  endpoint   text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;
drop policy if exists "push: mie"        on public.push_subs;
drop policy if exists "push: iscrivimi"  on public.push_subs;
drop policy if exists "push: aggiorna"   on public.push_subs;
drop policy if exists "push: cancella"   on public.push_subs;
create policy "push: mie"       on public.push_subs for select to authenticated using (user_id = auth.uid());
create policy "push: iscrivimi" on public.push_subs for insert to authenticated with check (user_id = auth.uid());
create policy "push: aggiorna"  on public.push_subs for update to authenticated using (true) with check (user_id = auth.uid());
create policy "push: cancella"  on public.push_subs for delete to authenticated using (user_id = auth.uid());

-- ---------- 2. Il collegamento alla Edge Function ----------
create or replace function public.manda_avviso(uids uuid[], titolo text, testo text, etichetta text default 'casa')
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if uids is null or array_length(uids, 1) is null then return; end if;
  perform net.http_post(
    url     := 'https://vbxxbxtknnxnodicvwsp.supabase.co/functions/v1/avvisi',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-casa-secret', 'INCOLLA_QUI_IL_SEGRETO'),
    body    := jsonb_build_object('uids', to_jsonb(uids), 'title', titolo, 'body', testo, 'tag', etichetta)
  );
end $$;

-- ---------- 3. Spesa: avvisa gli altri quando qualcuno aggiunge qualcosa ----------
create or replace function public.avviso_spesa() returns trigger
language plpgsql security definer set search_path = public as $$
declare altri uuid[]; chi text;
begin
  select array_agg(id) into altri from public.profiles where id <> new.aggiunto_da;
  select coalesce(nome, 'Qualcuno') into chi from public.profiles where id = new.aggiunto_da;
  perform public.manda_avviso(altri, 'Lista della spesa', chi || ' ha aggiunto ' || new.nome, 'spesa');
  return new;
end $$;
drop trigger if exists trg_avviso_spesa on public.shopping;
create trigger trg_avviso_spesa after insert on public.shopping
  for each row execute function public.avviso_spesa();

-- ---------- 4. Cambi turno: richiesta e risposta ----------
create or replace function public.avviso_cambio() returns trigger
language plpgsql security definer set search_path = public as $$
declare chi text;
begin
  if tg_op = 'INSERT' then
    select coalesce(nome,'Qualcuno') into chi from public.profiles where id = new.richiedente;
    perform public.manda_avviso(array[new.destinatario], 'Cambio turno',
            chi || ' ti chiede di fare un suo turno di pulizia', 'cambio');
  elsif new.stato in ('accettato','rifiutato') and old.stato = 'attesa' then
    select coalesce(nome,'Qualcuno') into chi from public.profiles where id = new.destinatario;
    perform public.manda_avviso(array[new.richiedente], 'Cambio turno',
            chi || ' ha ' || new.stato || ' il cambio', 'cambio');
  end if;
  return new;
end $$;
drop trigger if exists trg_avviso_cambio on public.chore_swaps;
create trigger trg_avviso_cambio after insert or update on public.chore_swaps
  for each row execute function public.avviso_cambio();

-- ---------- 5. Chi è di turno (stesso giro dell'app) ----------
create or replace function public.turno_di(p_sett date, p_turno text) returns uuid
language plpgsql stable set search_path = public as $$
declare n int; w int; idx int; who uuid; rec record;
begin
  select count(*) into n from public.profiles;
  if n = 0 then return null; end if;
  w := floor((p_sett - date '2026-01-05') / 7)::int + 0;   -- + ROT_SPOSTA, come nell'app
  idx := case when p_turno = 'we-cucina' then ((w % n) + n) % n
                                         else (((w - 1) % n) + n) % n end;
  select id into who from public.profiles order by nome offset idx limit 1;
  for rec in select * from public.chore_swaps where stato = 'accettato' order by created_at loop
    if rec.settimana = p_sett and rec.turno = p_turno then who := rec.destinatario;
    elsif rec.cambio_settimana = p_sett and rec.cambio_turno = p_turno then who := rec.richiedente;
    end if;
  end loop;
  return who;
end $$;

-- ---------- 6. Promemoria del mattino nei giorni di pulizia ----------
create or replace function public.promemoria_turni() returns void
language plpgsql security definer set search_path = public as $$
declare lun date := (current_date - ((extract(isodow from current_date)::int - 1)))::date;
        giorno int := extract(isodow from current_date)::int;
        turni text[]; t text; chi uuid; fatto timestamptz; nome_f text;
begin
  if giorno = 3 then turni := array['mer-bagno'];
  elsif giorno = 6 then turni := array['we-bagno','we-cucina'];
  else return; end if;
  foreach t in array turni loop
    select completato_il into fatto from public.chore_log where settimana = lun and turno = t;
    if fatto is not null then continue; end if;
    chi := public.turno_di(lun, t);
    if chi is null then continue; end if;
    nome_f := case when t = 'we-cucina' then 'Pulire la cucina' else 'Pulire bagno e corridoio' end;
    perform public.manda_avviso(array[chi], 'Oggi tocca a te', nome_f || '. Apri l''app per la checklist.', 'turno');
  end loop;
end $$;

-- ---------- 7. Promemoria dei turni in ritardo (domenica sera) ----------
create or replace function public.promemoria_ritardi() returns void
language plpgsql security definer set search_path = public as $$
declare lun date := (current_date - ((extract(isodow from current_date)::int - 1)))::date;
        t text; chi uuid; fatto timestamptz;
begin
  foreach t in array array['mer-bagno','we-bagno','we-cucina'] loop
    select completato_il into fatto from public.chore_log where settimana = lun and turno = t;
    if fatto is not null then continue; end if;
    chi := public.turno_di(lun, t);
    if chi is not null then
      perform public.manda_avviso(array[chi], 'Turno non ancora fatto',
              'La settimana finisce stasera e la tua checklist non è completa.', 'turno');
    end if;
  end loop;
end $$;

-- ---------- 8. Orari automatici (orari in UTC: +1h d'inverno, +2h d'estate) ----------
select cron.unschedule(jobname) from cron.job
  where jobname in ('promemoria-turni','promemoria-ritardi');
select cron.schedule('promemoria-turni',   '0 8 * * *', $$select public.promemoria_turni()$$);    -- ~10:00 in Italia
select cron.schedule('promemoria-ritardi', '0 18 * * 7', $$select public.promemoria_ritardi()$$); -- domenica ~20:00
