-- Disposable PostgreSQL only. Minimal Supabase roles and interfaces used by cleaning.
create role anon;
create role authenticated;
create role service_role bypassrls;

create schema auth;
create function auth.uid()
returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated;

create table public.profiles (
  id uuid primary key,
  nome text not null,
  stato text not null,
  is_guest boolean not null default false,
  is_admin boolean not null default false,
  ordine_giro integer
);

create table public.chore_log (
  settimana date not null,
  turno text not null,
  passi jsonb not null default '[]'::jsonb,
  completato_il timestamptz,
  aggiornato_da uuid references public.profiles(id),
  primary key (settimana, turno)
);

create table public.chore_swaps (
  id uuid primary key default gen_random_uuid(),
  settimana date not null,
  turno text not null,
  richiedente uuid not null references public.profiles(id),
  destinatario uuid not null references public.profiles(id),
  cambio_settimana date,
  cambio_turno text,
  stato text not null,
  risposto_il timestamptz,
  created_at timestamptz not null default now()
);

create table public.giro_versioni (
  dal date primary key,
  giro uuid[] not null
);

create table public.casa_config (
  id integer primary key,
  checklist jsonb not null default '{}'::jsonb
);

create schema cron;
create table cron.job (
  jobid bigint generated always as identity primary key,
  jobname name not null unique,
  schedule text not null,
  command text not null,
  active boolean not null default true
);

create function cron.schedule(job_name text, schedule text, command text)
returns bigint
language sql
as $$
  insert into cron.job as j(jobname, schedule, command)
  values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid
$$;

create function cron.alter_job(job_id bigint, command text default null)
returns void
language sql
as $$
  update cron.job set command = coalesce(alter_job.command, job.command)
  where jobid = job_id
$$;

insert into cron.job (jobname, schedule, command) values
  ('promemoria-turni', '0 7 * * 3,6', 'select public.ricorda_pulizie()'),
  ('promemoria-ritardi', '0 19 * * 0', 'select public.pulizie_scadute()'),
  ('frejus-unrelated-test', '0 12 * * *', 'select 1');

create schema test_support;
create table test_support.push_requests (
  recipients uuid[] not null,
  title text not null,
  body text not null,
  tag text not null
);

create function public.manda_avviso(p_uids uuid[], p_title text, p_body text, p_tag text)
returns void
language sql
as $$
  insert into test_support.push_requests values (p_uids, p_title, p_body, p_tag)
$$;

insert into public.profiles(id, nome, stato, is_guest, is_admin, ordine_giro) values
  ('00000000-0000-4000-8000-000000000001', 'Alice', 'coinquilino', false, true, 1),
  ('00000000-0000-4000-8000-000000000002', 'Bruno', 'coinquilino', false, false, 2),
  ('00000000-0000-4000-8000-000000000003', 'Carla', 'coinquilino', false, false, 3),
  ('00000000-0000-4000-8000-000000000004', 'Dario', 'coinquilino', false, false, 4),
  ('00000000-0000-4000-8000-000000000005', 'Ospite', 'ospite', true, false, null),
  ('00000000-0000-4000-8000-000000000006', 'In attesa', 'attesa', false, false, null);

insert into public.chore_log values
  ('2026-12-28', 'we-bagno', '["corridoio","wc"]', '2027-01-02 16:30:00+01', '00000000-0000-4000-8000-000000000002');
