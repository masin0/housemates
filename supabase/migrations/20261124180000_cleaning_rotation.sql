-- Additive migration. A future Monday must be selected before enabling the new rota.
begin;

create schema housemates_cleaning;
revoke all on schema housemates_cleaning from public, anon, authenticated;

create table housemates_cleaning.settings (
  singleton boolean primary key default true check (singleton),
  activation_week date check (extract(isodow from activation_week) = 1)
);
insert into housemates_cleaning.settings default values;

create table housemates_cleaning.slots (
  kind text primary key,
  room text not null,
  first_day integer not null,
  last_day integer not null,
  load_weight numeric not null check (load_weight > 0),
  sort_order integer not null unique,
  weekly boolean not null default true
);
insert into housemates_cleaning.slots values
  ('mer-bagno', 'bagno', 2, 3, 1.25, 1, true),
  ('we-bagno', 'bagno', 5, 6, 1.25, 2, true),
  ('we-cucina', 'cucina', 5, 6, 1.50, 3, true),
  ('we-corridoio', 'corridoio', 5, 6, 0.50, 4, true),
  ('balcone', 'balcone', 5, 6, 0.50, 5, false);

create table housemates_cleaning.instructions (
  room text primary key,
  steps text[] not null check (cardinality(steps) between 1 and 30)
);
insert into housemates_cleaning.instructions values
  ('bagno', array[
    'Pulire WC e bidet.', 'Pulire lavabo e rubinetti.', 'Pulire lo specchio.',
    'Pulire la doccia.', 'Pulire ripiani e superfici d''appoggio.',
    'Pulire sopra la lavatrice.', 'Passare aspirapolvere o scopa.',
    'Lavare il pavimento.', 'Svuotare il cestino soltanto se pieno.'
  ]),
  ('cucina', array[
    'Pulire il tavolo.', 'Pulire i piani di lavoro.', 'Pulire il piano a induzione.',
    'Pulire la parete dietro il piano a induzione.', 'Pulire il lavello.',
    'Pulire gli spazi e i cassetti comuni.',
    'Spostare i piatti per pulire il ripiano sottostante.',
    'Pulire sotto la macchina del caffè.',
    'Svuotare e pulire la vaschetta raccogligocce quando necessario.',
    'Passare aspirapolvere o scopa.', 'Lavare il pavimento.',
    'Svuotare la spazzatura soltanto se piena.'
  ]),
  ('corridoio', array[
    'Riordinare.', 'Passare scopa o aspirapolvere, anche negli angoli.',
    'Lavare il pavimento.', 'Lasciare asciugare e arieggiare.'
  ]),
  ('balcone', array['Riordinare.', 'Spazzare.', 'Lavare il pavimento.']);

create table housemates_cleaning.absences (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  starts_on date not null,
  ends_on date not null check (ends_on >= starts_on)
);
create index cleaning_absences_profile_dates on housemates_cleaning.absences
  (profile_id, starts_on, ends_on);

create table housemates_cleaning.turns (
  id uuid primary key default gen_random_uuid(),
  week date not null check (extract(isodow from week) = 1),
  kind text not null references housemates_cleaning.slots(kind),
  -- These are historical participant IDs. Profile removal must not delete turns or be blocked by them.
  assignee uuid,
  chosen_date date,
  status text not null check (status in ('choose_day', 'scheduled', 'completed', 'recovery', 'suspended')),
  recovery_cycle boolean not null default false,
  completed_at timestamptz,
  completed_by uuid,
  reassigned_at timestamptz,
  reported_by uuid,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check ((status = 'suspended') = (assignee is null)),
  check ((status = 'completed') = (completed_at is not null and completed_by is not null)),
  check (status <> 'scheduled' or chosen_date is not null),
  check (kind = 'balcone' or reported_by is null)
);
create unique index cleaning_weekly_slot on housemates_cleaning.turns (week, kind)
  where kind <> 'balcone';
create unique index cleaning_one_open_balcony on housemates_cleaning.turns (kind)
  where kind = 'balcone' and status <> 'completed';
create index cleaning_turns_assignee_week on housemates_cleaning.turns (assignee, week);
create index cleaning_turns_week on housemates_cleaning.turns (week);

create table housemates_cleaning.swaps (
  id uuid primary key default gen_random_uuid(),
  turn_id uuid not null references housemates_cleaning.turns(id),
  requester uuid not null,
  recipient uuid not null check (recipient <> requester),
  exchange_turn_id uuid references housemates_cleaning.turns(id) check (exchange_turn_id <> turn_id),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  created_at timestamptz not null default statement_timestamp(),
  answered_at timestamptz
);
create unique index cleaning_one_pending_swap on housemates_cleaning.swaps (turn_id)
  where status = 'pending';

alter table housemates_cleaning.settings enable row level security;
alter table housemates_cleaning.slots enable row level security;
alter table housemates_cleaning.instructions enable row level security;
alter table housemates_cleaning.absences enable row level security;
alter table housemates_cleaning.turns enable row level security;
alter table housemates_cleaning.swaps enable row level security;
revoke all on all tables in schema housemates_cleaning from public, anon, authenticated;

create function housemates_cleaning.lock_planning() returns void
language sql set search_path = ''
as $$ select pg_catalog.pg_advisory_xact_lock(904276, 1) $$;

create function housemates_cleaning.monday(p_day date) returns date
language sql immutable strict set search_path = ''
as $$ select p_day - (extract(isodow from p_day)::integer - 1) $$;

create function housemates_cleaning.is_member(p_profile uuid) returns boolean
language sql stable set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = p_profile and stato = 'coinquilino' and not coalesce(is_guest, false)
  )
$$;

create function housemates_cleaning.require_member() returns uuid
language plpgsql stable set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not housemates_cleaning.is_member(v_actor) then
    raise exception 'Questa funzione è riservata ai coinquilini.' using errcode = '42501';
  end if;
  return v_actor;
end;
$$;

create function housemates_cleaning.is_present(p_profile uuid, p_day date) returns boolean
language sql stable set search_path = ''
as $$
  select housemates_cleaning.is_member(p_profile) and not exists (
    select 1 from housemates_cleaning.absences
    where profile_id = p_profile and p_day between starts_on and ends_on
  )
$$;

create function housemates_cleaning.slot_dates(
  p_week date, p_kind text, p_profile uuid, p_from date
) returns date[]
language sql stable set search_path = ''
as $$
  select array(
    select p_week + offset_day
    from housemates_cleaning.slots s
    cross join lateral generate_series(s.first_day, s.last_day) as days(offset_day)
    where s.kind = p_kind
      and p_week + offset_day >= p_from
      and housemates_cleaning.is_present(p_profile, p_week + offset_day)
    order by offset_day
  )
$$;

create function housemates_cleaning.eligible_dates(
  p_turn housemates_cleaning.turns, p_profile uuid, p_today date
) returns date[]
language sql stable set search_path = ''
as $$
  select case when p_turn.recovery_cycle or p_turn.status = 'recovery' then
    array(
      select p_today + offset_day
      from generate_series(0, 6) as days(offset_day)
      where housemates_cleaning.is_present(p_profile, p_today + offset_day)
      order by offset_day
    )
  else
    housemates_cleaning.slot_dates(p_turn.week, p_turn.kind, p_profile, p_today)
  end
$$;

create function housemates_cleaning.best_assignee(
  p_turn housemates_cleaning.turns, p_week date, p_today date
) returns uuid
language sql stable set search_path = ''
as $$
  select p.id
  from public.profiles p
  cross join lateral (
    select
      count(*) filter (where t.week = p_week and (p_turn.kind = 'balcone' or t.kind <> 'balcone')) as concurrent_slots,
      coalesce(sum(s.load_weight) filter (where t.week = p_week), 0) as concurrent_load,
      count(*) filter (where t.week < p_week and s.room = target.room) as room_total,
      count(*) filter (where t.week < p_week and t.kind = p_turn.kind) as slot_total,
      coalesce(sum(s.load_weight) filter (where t.week < p_week), 0) as historic_load,
      max(t.week) filter (where t.week < p_week and t.kind = p_turn.kind) as last_same_slot,
      max(t.week) filter (where t.week < p_week and s.room = target.room) as last_same_room
    from housemates_cleaning.turns t
    join housemates_cleaning.slots s on s.kind = t.kind
    join housemates_cleaning.slots target on target.kind = p_turn.kind
    where t.assignee = p.id and t.week <= p_week and t.id <> p_turn.id
  ) as load
  where cardinality(housemates_cleaning.slot_dates(p_week, p_turn.kind, p.id, p_today)) > 0
  order by load.concurrent_slots,
           case when p_turn.kind = 'balcone' then load.slot_total else 0 end,
           load.concurrent_load, load.room_total, load.slot_total, load.historic_load,
           load.last_same_slot nulls first, load.last_same_room nulls first,
           p.ordine_giro nulls last, p.id
  limit 1
$$;

create function housemates_cleaning.set_assignee(
  p_turn housemates_cleaning.turns, p_assignee uuid, p_now timestamptz
) returns void
language plpgsql set search_path = ''
as $$
begin
  update housemates_cleaning.turns
  set assignee = p_assignee,
      chosen_date = null,
      status = case when p_assignee is null then 'suspended'
                    when recovery_cycle then 'recovery'
                    else 'choose_day' end,
      reassigned_at = case when assignee is not null and assignee is distinct from p_assignee
                           then p_now else reassigned_at end,
      updated_at = p_now
  where id = p_turn.id and status <> 'completed';

  if p_turn.assignee is distinct from p_assignee then
    update housemates_cleaning.swaps
    set status = 'cancelled', answered_at = p_now
    where status = 'pending' and (turn_id = p_turn.id or exchange_turn_id = p_turn.id);
  end if;
end;
$$;

create function housemates_cleaning.reconcile_week(p_week date, p_now timestamptz)
returns void language plpgsql set search_path = ''
as $$
declare
  v_today date := timezone('Europe/Rome', p_now)::date;
  v_turn housemates_cleaning.turns;
  v_candidate uuid;
  v_last_day integer;
begin
  insert into housemates_cleaning.turns (week, kind, status, created_at, updated_at)
  select p_week, s.kind, 'suspended', p_now, p_now
  from housemates_cleaning.slots s where s.weekly
  on conflict (week, kind) where kind <> 'balcone' do nothing;

  for v_turn in
    select t.*
    from housemates_cleaning.turns t
    join housemates_cleaning.slots s on s.kind = t.kind
    where t.week = p_week and s.weekly and t.status not in ('completed', 'recovery')
    order by (select count(*) from public.profiles p where
      cardinality(housemates_cleaning.slot_dates(p_week, t.kind, p.id, v_today)) > 0),
      s.sort_order
  loop
    if v_turn.status = 'scheduled' and v_turn.chosen_date < v_today then
      continue; -- A silent evening confirmation remains pending.
    end if;
    if v_turn.status = 'scheduled'
       and housemates_cleaning.is_present(v_turn.assignee, v_turn.chosen_date) then
      continue;
    end if;
    if v_turn.recovery_cycle then
      perform housemates_cleaning.set_assignee(v_turn, v_turn.assignee, p_now);
      continue;
    end if;
    if v_turn.assignee is not null and
       cardinality(housemates_cleaning.slot_dates(p_week, v_turn.kind, v_turn.assignee, v_today)) > 0 then
      if v_turn.status = 'scheduled' then
        perform housemates_cleaning.set_assignee(v_turn, v_turn.assignee, p_now);
      end if;
      continue;
    end if;

    select last_day into v_last_day from housemates_cleaning.slots where kind = v_turn.kind;
    if v_today > p_week + v_last_day then
      if v_turn.status = 'choose_day' then
        update housemates_cleaning.turns
        set status = 'recovery', recovery_cycle = true, updated_at = p_now
        where id = v_turn.id;
      end if;
      continue;
    end if;

    v_candidate := housemates_cleaning.best_assignee(v_turn, p_week, v_today);
    if v_candidate is distinct from v_turn.assignee then
      perform housemates_cleaning.set_assignee(v_turn, v_candidate, p_now);
    end if;
  end loop;
end;
$$;

create function housemates_cleaning.reconcile_balcony(p_now timestamptz) returns void
language plpgsql set search_path = ''
as $$
declare
  v_today date := timezone('Europe/Rome', p_now)::date;
  v_week date := housemates_cleaning.monday(v_today);
  v_turn housemates_cleaning.turns;
  v_candidate uuid;
begin
  select * into v_turn from housemates_cleaning.turns
  where kind = 'balcone' and status <> 'completed';
  if not found or v_turn.status = 'recovery'
     or (v_turn.status = 'scheduled' and (
          v_turn.chosen_date < v_today or housemates_cleaning.is_present(v_turn.assignee, v_turn.chosen_date)
     )) then
    return;
  end if;
  if v_turn.recovery_cycle then
    perform housemates_cleaning.set_assignee(v_turn, v_turn.assignee, p_now);
    return;
  end if;
  if v_turn.assignee is not null and cardinality(
    housemates_cleaning.slot_dates(v_turn.week, v_turn.kind, v_turn.assignee, v_today)
  ) > 0 then
    if v_turn.status = 'scheduled' then
      perform housemates_cleaning.set_assignee(v_turn, v_turn.assignee, p_now);
    end if;
    return;
  end if;
  for v_offset in 0..4 loop
    v_week := housemates_cleaning.monday(v_today) + 7 * v_offset;
    v_candidate := housemates_cleaning.best_assignee(v_turn, v_week, v_today);
    exit when v_candidate is not null;
  end loop;
  if v_candidate is null then
    if v_turn.assignee is not null then
      perform housemates_cleaning.set_assignee(v_turn, null, p_now);
    end if;
    return;
  end if;
  update housemates_cleaning.turns set week = v_week where id = v_turn.id;
  perform housemates_cleaning.set_assignee(v_turn, v_candidate, p_now);
end;
$$;

create function housemates_cleaning.ensure_weeks(p_through date, p_now timestamptz) returns void
language plpgsql set search_path = ''
as $$
declare
  v_today date := timezone('Europe/Rome', p_now)::date;
  v_current date := housemates_cleaning.monday(v_today);
  v_first date;
  v_last date;
  v_existing date;
  v_week date;
begin
  perform housemates_cleaning.lock_planning();
  select activation_week into v_first from housemates_cleaning.settings;
  if v_first is null then
    return;
  end if;

  -- Failure to choose a day is distinct from a scheduled turn awaiting an answer.
  update housemates_cleaning.turns
  set status = 'recovery', recovery_cycle = true, updated_at = p_now
  where week >= v_first and week < v_current and kind <> 'balcone' and status = 'choose_day';

  -- A recovery date can fall in a different week than its original recurring slot.
  update housemates_cleaning.turns
  set status = 'recovery', chosen_date = null, updated_at = p_now
  where week >= v_first and week < v_current and recovery_cycle and status = 'scheduled'
    and chosen_date >= v_today and not housemates_cleaning.is_present(assignee, chosen_date);

  select max(week) into v_existing from housemates_cleaning.turns where kind <> 'balcone';
  v_last := least(greatest(v_current, housemates_cleaning.monday(p_through)), v_current + 371);
  if v_first <= v_current then
    perform housemates_cleaning.reconcile_week(v_current, p_now);
    perform housemates_cleaning.reconcile_balcony(p_now);
  end if;
  v_week := greatest(v_current + 7, v_first, v_existing + 7);
  while v_week <= v_last loop
    perform housemates_cleaning.reconcile_week(v_week, p_now);
    v_week := v_week + 7;
  end loop;
end;
$$;

create function housemates_cleaning.reconcile_absence_change(p_now timestamptz) returns void
language plpgsql set search_path = ''
as $$
declare
  v_today date := timezone('Europe/Rome', p_now)::date;
  v_current date := housemates_cleaning.monday(v_today);
  v_week date;
  v_turn housemates_cleaning.turns;
  v_candidate uuid;
begin
  perform housemates_cleaning.ensure_weeks(v_current + 7, p_now);
  for v_week in
    select distinct week from housemates_cleaning.turns
    where week >= v_current and kind <> 'balcone'
    order by week
  loop
    if v_week > v_current then
      perform housemates_cleaning.reconcile_week(v_week, p_now);
    end if;

    -- A returning resident can free a colleague from a second, still unplanned turn.
    for v_turn in
      select t.* from housemates_cleaning.turns t
      join housemates_cleaning.slots s on s.kind = t.kind
      where t.week = v_week and t.status = 'choose_day' and s.weekly
        and t.reassigned_at is null and not exists (
          select 1 from housemates_cleaning.swaps sw
          where sw.status = 'pending' and (sw.turn_id = t.id or sw.exchange_turn_id = t.id)
        )
      order by s.load_weight asc, s.sort_order
    loop
      v_candidate := housemates_cleaning.best_assignee(v_turn, v_week, v_today);
      if v_candidate is not null and v_candidate <> v_turn.assignee and
        (select count(*) from housemates_cleaning.turns where week = v_week and assignee = v_candidate and kind <> 'balcone') + 1 <
        (select count(*) from housemates_cleaning.turns where week = v_week and assignee = v_turn.assignee and kind <> 'balcone') then
        perform housemates_cleaning.set_assignee(v_turn, v_candidate, p_now);
      end if;
    end loop;
  end loop;
end;
$$;

create function housemates_cleaning.confirm_due(
  p_turn housemates_cleaning.turns, p_now timestamptz
) returns boolean language sql stable set search_path = ''
as $$
  select p_turn.status = 'scheduled' and
    timezone('Europe/Rome', p_now) >= p_turn.chosen_date + time '23:00'
$$;

create function housemates_cleaning.can_complete(
  p_turn housemates_cleaning.turns, p_actor uuid, p_now timestamptz
) returns boolean language sql stable set search_path = ''
as $$
  select p_turn.assignee = p_actor and
    housemates_cleaning.is_present(p_actor, timezone('Europe/Rome', p_now)::date) and
    (p_turn.status = 'recovery' or
      (p_turn.status = 'scheduled' and p_turn.chosen_date <= timezone('Europe/Rome', p_now)::date))
$$;

create function housemates_cleaning.can_swap(
  p_turn housemates_cleaning.turns, p_today date
) returns boolean language sql stable set search_path = ''
as $$
  select p_turn.assignee is not null
    and p_turn.status in ('choose_day', 'scheduled', 'recovery')
    and (p_turn.status <> 'scheduled' or p_turn.chosen_date >= p_today)
    and (p_turn.recovery_cycle or exists (
      select 1 from housemates_cleaning.slots
      where kind = p_turn.kind and p_turn.week + last_day >= p_today
    ))
$$;

create function housemates_cleaning.turn_json(
  p_turn housemates_cleaning.turns, p_actor uuid, p_now timestamptz
) returns jsonb language sql stable set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_turn.id, 'week', p_turn.week, 'kind', p_turn.kind,
    'assignee', p_turn.assignee, 'chosen_date', p_turn.chosen_date, 'status', p_turn.status,
    'completed_at', p_turn.completed_at, 'completed_by', p_turn.completed_by,
    'reassigned_at', p_turn.reassigned_at,
    'starts_on', p_turn.week + s.first_day, 'ends_on', p_turn.week + s.last_day,
    'eligible_dates', case when p_turn.status in ('choose_day', 'scheduled', 'recovery')
                           then housemates_cleaning.eligible_dates(
                             p_turn, p_turn.assignee, timezone('Europe/Rome', p_now)::date
                           ) else array[]::date[] end,
    'can_complete', coalesce(housemates_cleaning.can_complete(p_turn, p_actor, p_now), false),
    'confirm_due', coalesce(p_turn.assignee = p_actor and housemates_cleaning.confirm_due(p_turn, p_now), false),
    'can_swap', housemates_cleaning.can_swap(p_turn, timezone('Europe/Rome', p_now)::date)
  )
  from housemates_cleaning.slots s where s.kind = p_turn.kind
$$;

create function housemates_cleaning.snapshot(p_week date, p_now timestamptz)
returns jsonb language plpgsql set search_path = ''
as $$
declare
  v_actor uuid := housemates_cleaning.require_member();
  v_today date := timezone('Europe/Rome', p_now)::date;
  v_current date := housemates_cleaning.monday(v_today);
  v_week date := housemates_cleaning.monday(coalesce(p_week, v_today));
  v_first date;
  v_active boolean;
  v_paused boolean;
  v_return date;
begin
  select activation_week into v_first from housemates_cleaning.settings;
  v_active := v_first is not null and v_week >= v_first;
  if v_week > v_current + 371 then
    raise exception 'Puoi consultare i turni fino a un anno in avanti.';
  end if;
  if v_active then
    perform housemates_cleaning.ensure_weeks(v_week, p_now);
  end if;
  v_paused := not exists (
    select 1 from public.profiles p where housemates_cleaning.is_present(p.id, v_today)
  );
  if v_paused then
    select min(a.ends_on + 1) into v_return
    from housemates_cleaning.absences a
    where a.ends_on >= v_today and exists (
      select 1 from public.profiles p where housemates_cleaning.is_present(p.id, a.ends_on + 1)
    );
  end if;
  return jsonb_build_object(
    'active', v_active, 'enabled', v_first is not null, 'activation_week', v_first,
    'today', v_today, 'week', v_week, 'paused', v_paused, 'returns_on', v_return,
    'balcony_pending', exists (
      select 1 from housemates_cleaning.turns where kind = 'balcone' and status <> 'completed'
    ),
    'turns', coalesce((
      select jsonb_agg(housemates_cleaning.turn_json(t, v_actor, p_now) order by s.sort_order, t.created_at)
      from housemates_cleaning.turns t join housemates_cleaning.slots s on s.kind = t.kind
      where v_active and t.week = v_week
    ), '[]'::jsonb),
    'personal_open', coalesce((
      select jsonb_agg(housemates_cleaning.turn_json(t, v_actor, p_now) order by t.week, t.created_at)
      from housemates_cleaning.turns t
      where t.assignee = v_actor and t.week < v_current and t.status in ('recovery', 'scheduled')
    ), '[]'::jsonb),
    'absences', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'starts_on', a.starts_on, 'ends_on', a.ends_on)
                       order by a.starts_on, a.id)
      from housemates_cleaning.absences a where a.profile_id = v_actor and a.ends_on >= v_today
    ), '[]'::jsonb),
    'instructions', (select jsonb_object_agg(room, steps) from housemates_cleaning.instructions),
    'swaps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', sw.id, 'turn_id', sw.turn_id, 'requester', sw.requester,
        'recipient', sw.recipient, 'exchange_turn_id', sw.exchange_turn_id, 'status', sw.status,
        'kind', t.kind, 'week', t.week, 'exchange_kind', e.kind, 'exchange_week', e.week
      ) order by sw.created_at desc)
      from housemates_cleaning.swaps sw
      join housemates_cleaning.turns t on t.id = sw.turn_id
      left join housemates_cleaning.turns e on e.id = sw.exchange_turn_id
      where v_actor in (sw.requester, sw.recipient) and
        (sw.status = 'pending' or t.week = v_week or e.week = v_week)
    ), '[]'::jsonb)
  );
end;
$$;

create function housemates_cleaning.require_transfer(
  p_turn housemates_cleaning.turns, p_recipient uuid, p_today date
) returns void language plpgsql set search_path = ''
as $$
begin
  if p_turn.id is null or not housemates_cleaning.can_swap(p_turn, p_today) then
    raise exception 'Questo turno non è più disponibile per la riassegnazione.';
  end if;
  if cardinality(housemates_cleaning.eligible_dates(p_turn, p_recipient, p_today)) = 0 then
    raise exception 'Il coinquilino non è disponibile nei giorni del turno.';
  end if;
end;
$$;

create function housemates_cleaning.action(p_action text, p_payload jsonb, p_now timestamptz)
returns jsonb language plpgsql set search_path = ''
as $$
declare
  v_actor uuid := housemates_cleaning.require_member();
  v_today date := timezone('Europe/Rome', p_now)::date;
  v_current date := housemates_cleaning.monday(v_today);
  v_first date;
  v_admin boolean;
  v_turn housemates_cleaning.turns;
  v_exchange housemates_cleaning.turns;
  v_swap housemates_cleaning.swaps;
  v_id uuid;
  v_recip uuid;
  v_date date;
  v_end date;
  v_room text;
  v_steps text[];
  v_answer boolean;
begin
  perform housemates_cleaning.lock_planning();
  select activation_week into v_first from housemates_cleaning.settings;
  if v_first is null then
    raise exception 'Il nuovo calendario delle pulizie non è ancora attivo.';
  end if;
  select coalesce(is_admin, false) into v_admin from public.profiles where id = v_actor;
  if p_action in ('admin_assign', 'admin_instructions') and not v_admin then
    raise exception 'Questa funzione è riservata agli amministratori.' using errcode = '42501';
  end if;
  select * into v_turn from housemates_cleaning.turns where id = (p_payload->>'turn_id')::uuid;

  case p_action
    when 'choose_day', 'complete', 'confirm' then
      if v_turn.assignee is distinct from v_actor then
        raise exception 'Solo il responsabile può aggiornare il turno.' using errcode = '42501';
      end if;
      if v_turn.status = 'completed' and p_action <> 'choose_day' then
        return jsonb_build_object('ok', true);
      end if;
      if p_action = 'choose_day' then
        v_date := (p_payload->>'date')::date;
        if v_turn.status not in ('choose_day', 'scheduled', 'recovery')
           or housemates_cleaning.confirm_due(v_turn, p_now)
           or not coalesce(v_date = any(housemates_cleaning.eligible_dates(v_turn, v_actor, v_today)), false) then
          raise exception 'Scegli un giorno disponibile a partire da oggi.';
        end if;
        update housemates_cleaning.turns
        set chosen_date = v_date, status = 'scheduled', updated_at = p_now
        where id = v_turn.id and (chosen_date is distinct from v_date or status <> 'scheduled');
      else
        if p_action = 'confirm' then
          if jsonb_typeof(p_payload->'answer') is distinct from 'boolean' then
            raise exception 'Scegli Sì oppure No.';
          end if;
          v_answer := (p_payload->>'answer')::boolean;
          if not housemates_cleaning.confirm_due(v_turn, p_now) then
            if v_turn.status = 'recovery' and not v_answer then
              return jsonb_build_object('ok', true);
            end if;
            raise exception 'La conferma è disponibile dalle 23:00 del giorno scelto.';
          end if;
        else
          v_answer := true;
        end if;
        if v_answer then
          if not housemates_cleaning.can_complete(v_turn, v_actor, p_now) then
            raise exception 'Il turno può essere confermato quando è programmato per oggi o da recuperare.';
          end if;
          update housemates_cleaning.turns
          set status = 'completed', completed_at = p_now, completed_by = v_actor, updated_at = p_now
          where id = v_turn.id and completed_at is null;
          update housemates_cleaning.swaps set status = 'cancelled', answered_at = p_now
          where status = 'pending' and (turn_id = v_turn.id or exchange_turn_id = v_turn.id);
        else
          update housemates_cleaning.turns
          set status = 'recovery', recovery_cycle = true, chosen_date = null, updated_at = p_now
          where id = v_turn.id;
        end if;
      end if;
    when 'absence_save' then
      v_id := (p_payload->>'id')::uuid;
      v_date := (p_payload->>'starts_on')::date;
      v_end := (p_payload->>'ends_on')::date;
      if v_date is null or v_end is null or v_end < greatest(v_date, v_today) or v_end - v_date > 730 then
        raise exception 'Indica un periodo di assenza valido.';
      end if;
      if v_id is null then
        insert into housemates_cleaning.absences (profile_id, starts_on, ends_on)
        values (v_actor, v_date, v_end);
      else
        update housemates_cleaning.absences set starts_on = v_date, ends_on = v_end
        where id = v_id and profile_id = v_actor;
        if not found then
          raise exception 'Assenza non disponibile.' using errcode = '42501';
        end if;
      end if;
      perform housemates_cleaning.reconcile_absence_change(p_now);
    when 'absence_delete' then
      delete from housemates_cleaning.absences
      where id = (p_payload->>'id')::uuid and profile_id = v_actor and ends_on >= v_today;
      if not found then
        raise exception 'Assenza non disponibile.' using errcode = '42501';
      end if;
      perform housemates_cleaning.reconcile_absence_change(p_now);
    when 'report_balcony' then
      if v_current < v_first then
        raise exception 'Le segnalazioni si aprono dalla settimana di attivazione.';
      end if;
      insert into housemates_cleaning.turns (week, kind, status, reported_by, created_at, updated_at)
      values (v_current, 'balcone', 'suspended', v_actor, p_now, p_now)
      on conflict (kind) where kind = 'balcone' and status <> 'completed' do nothing;
      perform housemates_cleaning.ensure_weeks(v_current, p_now);
    when 'swap_request' then
      v_recip := (p_payload->>'recipient')::uuid;
      if v_turn.assignee is distinct from v_actor or v_recip is not distinct from v_actor then
        raise exception 'Puoi proporre uno scambio soltanto per un tuo turno.' using errcode = '42501';
      end if;
      perform housemates_cleaning.require_transfer(v_turn, v_recip, v_today);
      if p_payload->>'exchange_turn_id' is not null then
        select * into v_exchange from housemates_cleaning.turns where id = (p_payload->>'exchange_turn_id')::uuid;
        if v_exchange.assignee is distinct from v_recip then
          raise exception 'Il secondo turno deve essere assegnato al destinatario.';
        end if;
        perform housemates_cleaning.require_transfer(v_exchange, v_actor, v_today);
      end if;
      insert into housemates_cleaning.swaps (turn_id, requester, recipient, exchange_turn_id, created_at)
      values (v_turn.id, v_actor, v_recip, v_exchange.id, p_now);
    when 'swap_reply', 'swap_cancel' then
      select * into v_swap from housemates_cleaning.swaps where id = (p_payload->>'id')::uuid;
      if v_swap.id is null or
         (p_action = 'swap_reply' and v_swap.recipient <> v_actor) or
         (p_action = 'swap_cancel' and v_swap.requester <> v_actor) then
        raise exception 'Non puoi modificare questa richiesta.' using errcode = '42501';
      end if;
      if v_swap.status <> 'pending' then
        raise exception 'Questa richiesta è già stata gestita.';
      end if;
      if p_action = 'swap_cancel' then
        update housemates_cleaning.swaps set status = 'cancelled', answered_at = p_now where id = v_swap.id;
      else
        if jsonb_typeof(p_payload->'accept') is distinct from 'boolean' then
          raise exception 'Scegli se accettare o rifiutare lo scambio.';
        end if;
        v_answer := (p_payload->>'accept')::boolean;
        if v_answer then
          select * into v_turn from housemates_cleaning.turns where id = v_swap.turn_id;
          if v_turn.assignee is distinct from v_swap.requester then
            raise exception 'Il responsabile del turno è cambiato.';
          end if;
          perform housemates_cleaning.require_transfer(v_turn, v_swap.recipient, v_today);
          if v_swap.exchange_turn_id is not null then
            select * into v_exchange from housemates_cleaning.turns where id = v_swap.exchange_turn_id;
            if v_exchange.assignee is distinct from v_swap.recipient then
              raise exception 'Il responsabile del secondo turno è cambiato.';
            end if;
            perform housemates_cleaning.require_transfer(v_exchange, v_swap.requester, v_today);
          end if;
        end if;
        update housemates_cleaning.swaps
        set status = case when v_answer then 'accepted' else 'declined' end, answered_at = p_now
        where id = v_swap.id;
        if v_answer then
          perform housemates_cleaning.set_assignee(v_turn, v_swap.recipient, p_now);
          if v_exchange.id is not null then
            perform housemates_cleaning.set_assignee(v_exchange, v_swap.requester, p_now);
          end if;
        end if;
      end if;
    when 'admin_assign' then
      v_recip := (p_payload->>'assignee')::uuid;
      perform housemates_cleaning.require_transfer(v_turn, v_recip, v_today);
      if v_recip is distinct from v_turn.assignee then
        perform housemates_cleaning.set_assignee(v_turn, v_recip, p_now);
      end if;
    when 'admin_instructions' then
      v_room := p_payload->>'room';
      if jsonb_typeof(p_payload->'steps') is distinct from 'array' then
        raise exception 'Inserisci le istruzioni come elenco.';
      end if;
      if exists (
        select 1 from jsonb_array_elements(p_payload->'steps') step(value)
        where jsonb_typeof(step.value) <> 'string' or length(step.value #>> '{}') > 250
      ) then
        raise exception 'Ogni istruzione deve avere al massimo 250 caratteri.';
      end if;
      select array_agg(btrim(step.value) order by step.position) into v_steps
      from jsonb_array_elements_text(p_payload->'steps') with ordinality as step(value, position)
      where btrim(step.value) <> '';
      if coalesce(cardinality(v_steps), 0) not between 1 and 30 then
        raise exception 'Inserisci da una a 30 istruzioni.';
      end if;
      update housemates_cleaning.instructions set steps = v_steps where room = v_room;
      if not found then
        raise exception 'Ambiente non riconosciuto.';
      end if;
    else
      raise exception 'Operazione di pulizia non riconosciuta.';
  end case;
  return jsonb_build_object('ok', true);
end;
$$;

-- Only the two clock-fixed entry points are granted to the authenticated role.
-- Their schema is not exposed through the Supabase Data API.
create function housemates_cleaning.read_current(p_week date) returns jsonb
language sql security definer set search_path = ''
as $$ select housemates_cleaning.snapshot(p_week, statement_timestamp()) $$;

create function housemates_cleaning.dispatch(p_action text, p_payload jsonb) returns jsonb
language sql security definer set search_path = ''
as $$ select housemates_cleaning.action(p_action, p_payload, statement_timestamp()) $$;

revoke all on all functions in schema housemates_cleaning from public, anon, authenticated;
grant usage on schema housemates_cleaning to authenticated;
grant execute on function housemates_cleaning.read_current(date) to authenticated;
grant execute on function housemates_cleaning.dispatch(text, jsonb) to authenticated;

create function public.cleaning_snapshot(p_week date) returns jsonb
language sql security invoker set search_path = ''
as $$ select housemates_cleaning.read_current(p_week) $$;

create function public.cleaning_action(p_action text, p_payload jsonb) returns jsonb
language sql security invoker set search_path = ''
as $$ select housemates_cleaning.dispatch(p_action, p_payload) $$;

revoke all on function public.cleaning_snapshot(date) from public, anon, authenticated;
revoke all on function public.cleaning_action(text, jsonb) from public, anon, authenticated;
grant execute on function public.cleaning_snapshot(date) to authenticated;
grant execute on function public.cleaning_action(text, jsonb) to authenticated;

commit;
