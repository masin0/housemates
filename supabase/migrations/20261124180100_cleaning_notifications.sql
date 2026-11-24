begin;

create table housemates_cleaning.notification_outbox (
    turn_id uuid not null references housemates_cleaning.turns(id) on delete cascade,
    recipient uuid not null references public.profiles(id) on delete cascade,
    event_type text not null check (event_type in ('choose', 'reminder', 'confirmation', 'completed', 'swap_request', 'swap_reply')),
    occasion text not null,
    title text not null,
    body text not null,
    next_attempt_at timestamptz not null,
    attempts integer not null default 0,
    queued_at timestamptz,
    primary key (turn_id, recipient, event_type, occasion)
);

alter table housemates_cleaning.notification_outbox enable row level security;
revoke all on housemates_cleaning.notification_outbox from public, anon, authenticated;
create index cleaning_notification_pending_idx
    on housemates_cleaning.notification_outbox (next_attempt_at) where queued_at is null;

create function housemates_cleaning.turn_label(p_kind text)
returns text language sql immutable strict set search_path = '' as $$
    select case p_kind
        when 'mer-bagno' then 'Bagno infrasettimanale'
        when 'we-bagno' then 'Bagno del weekend'
        when 'we-cucina' then 'Cucina'
        when 'we-corridoio' then 'Corridoio'
        when 'balcone' then 'Balcone'
    end;
$$;

create function housemates_cleaning.note_completion()
returns trigger language plpgsql set search_path = '' as $$
declare
    local_date date;
    cleaner text;
    weekday text;
begin
    if new.status <> 'completed' or old.status = 'completed' then
        return new;
    end if;

    local_date := (new.completed_at at time zone 'Europe/Rome')::date;
    select nome into cleaner from public.profiles where id = new.completed_by;
    weekday := (array['lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica'])
        [extract(isodow from local_date)::int];

    insert into housemates_cleaning.notification_outbox
        (turn_id, recipient, event_type, occasion, title, body, next_attempt_at)
    select new.id, p.id, 'completed', local_date::text, 'Pulizia completata ✨',
           format('%s ha completato la pulizia. %s, %s alle %s.',
               coalesce(cleaner, 'Un coinquilino'), housemates_cleaning.turn_label(new.kind),
               weekday, to_char(new.completed_at at time zone 'Europe/Rome', 'HH24:MI')),
           new.completed_at
    from public.profiles as p
    where p.stato = 'coinquilino' and not p.is_guest and p.id <> new.completed_by
    on conflict do nothing;
    return new;
end;
$$;

create trigger cleaning_completion_notice after update of status on housemates_cleaning.turns
    for each row execute function housemates_cleaning.note_completion();

create function housemates_cleaning.note_swap()
returns trigger language plpgsql set search_path = '' as $$
declare
    label text;
    name text;
    peer uuid;
    event text;
    title text;
    body text;
    occurred_at timestamptz;
begin
    select housemates_cleaning.turn_label(t.kind) into label
    from housemates_cleaning.turns as t where t.id = new.turn_id;

    if tg_op = 'INSERT' then
        select nome into name from public.profiles where id = new.requester;
        peer := new.recipient;
        event := 'swap_request';
        title := 'Richiesta di cambio turno';
        body := format('%s ti ha chiesto un cambio per %s. Rispondi in Turni.', name, label);
        occurred_at := new.created_at;
    elsif new.status in ('accepted', 'declined') and old.status = 'pending' then
        select nome into name from public.profiles where id = new.recipient;
        peer := new.requester;
        event := 'swap_reply';
        title := case new.status when 'accepted' then 'Cambio turno accettato' else 'Cambio turno rifiutato' end;
        body := format('%s ha risposto alla tua richiesta per %s. Apri Turni per vedere l’esito.', name, label);
        occurred_at := new.answered_at;
    else
        return new;
    end if;

    insert into housemates_cleaning.notification_outbox
        (turn_id, recipient, event_type, occasion, title, body, next_attempt_at)
    select new.turn_id, p.id, event, new.id::text, title, body, occurred_at
    from public.profiles as p where p.id = peer and p.stato = 'coinquilino' and not p.is_guest
    on conflict do nothing;
    return new;
end;
$$;

create trigger cleaning_swap_notice after insert or update of status on housemates_cleaning.swaps
    for each row execute function housemates_cleaning.note_swap();

create function housemates_cleaning.run_notifications(p_now timestamptz)
returns void language plpgsql set search_path = '' as $$
declare
    local_now timestamp := p_now at time zone 'Europe/Rome';
    today date := local_now::date;
    first_week date;
    notice housemates_cleaning.notification_outbox%rowtype;
begin
    select activation_week into first_week from housemates_cleaning.settings;
    if first_week is null or today < first_week then return; end if;

    perform housemates_cleaning.ensure_weeks(today, p_now);

    insert into housemates_cleaning.notification_outbox
        (turn_id, recipient, event_type, occasion, title, body, next_attempt_at)
    select t.id, t.assignee, 'choose', t.week::text, housemates_cleaning.turn_label(t.kind),
           case t.kind when 'mer-bagno' then 'Preferisci mercoledì o giovedì? Scegli il giorno in Turni.'
               when 'we-corridoio' then '🚪 Questo weekend ti tocca pulire il corridoio! Preferisci sabato o domenica?'
               else 'Preferisci sabato o domenica? Scegli il giorno in Turni.' end, p_now
    from housemates_cleaning.turns as t
    where t.status = 'choose_day' and t.assignee is not null
      and today between t.week and t.week + 6
      and local_now >= case t.kind when 'mer-bagno' then (t.week + 1) + time '19:00'
              when 'balcone' then t.created_at at time zone 'Europe/Rome'
              else (t.week + 4) + time '19:00' end
      and housemates_cleaning.is_present(t.assignee, today)
      and cardinality(housemates_cleaning.eligible_dates(t, t.assignee, today)) > 0
    on conflict do nothing;

    insert into housemates_cleaning.notification_outbox
        (turn_id, recipient, event_type, occasion, title, body, next_attempt_at)
    select t.id, t.assignee, 'reminder', t.chosen_date::text, 'Oggi tocca a te',
           housemates_cleaning.turn_label(t.kind) || '. Le istruzioni sono in Turni.', p_now
    from housemates_cleaning.turns as t
    where t.status = 'scheduled' and t.chosen_date = today
      and local_now::time >= time '09:00' and local_now::time < time '23:00'
    on conflict do nothing;

    insert into housemates_cleaning.notification_outbox
        (turn_id, recipient, event_type, occasion, title, body, next_attempt_at)
    select t.id, t.assignee, 'confirmation', t.chosen_date::text, 'Hai completato?',
           housemates_cleaning.turn_label(t.kind) || '. Apri HouseMates per rispondere Sì o No.', p_now
    from housemates_cleaning.turns as t
    where t.status = 'scheduled' and t.chosen_date between today - 1 and today
      and local_now >= t.chosen_date + time '23:00'
    on conflict do nothing;

    for notice in
        select n.* from housemates_cleaning.notification_outbox as n
        where n.queued_at is null and n.next_attempt_at <= p_now and n.attempts < 5
        order by n.next_attempt_at, n.turn_id, n.recipient, n.event_type, n.occasion
        limit 100 for update skip locked
    loop
        if (notice.event_type in ('choose', 'reminder', 'confirmation') and not exists (
            select 1 from housemates_cleaning.turns as t
            join public.profiles as p on p.id = t.assignee
            where t.id = notice.turn_id and t.assignee = notice.recipient
              and p.stato = 'coinquilino' and not p.is_guest
              and case notice.event_type
                  when 'choose' then t.status = 'choose_day'
                      and housemates_cleaning.is_present(t.assignee, today)
                      and cardinality(housemates_cleaning.eligible_dates(t, t.assignee, today)) > 0
                  when 'reminder' then t.status = 'scheduled' and t.chosen_date = today
                      and t.chosen_date::text = notice.occasion and local_now::time < time '23:00'
                  when 'confirmation' then t.status = 'scheduled' and t.chosen_date::text = notice.occasion
                  else false
              end
        )) or (notice.event_type = 'swap_request' and not exists (
            select 1 from housemates_cleaning.swaps as s
            where s.id::text = notice.occasion and s.status = 'pending'
        )) then
            delete from housemates_cleaning.notification_outbox
            where (turn_id, recipient, event_type, occasion) =
                  (notice.turn_id, notice.recipient, notice.event_type, notice.occasion);
            continue;
        end if;

        begin
            perform public.manda_avviso(array[notice.recipient], notice.title, notice.body,
                format('cleaning-%s-%s-%s', notice.event_type, notice.turn_id, notice.occasion));
            update housemates_cleaning.notification_outbox set queued_at = p_now
            where (turn_id, recipient, event_type, occasion) =
                  (notice.turn_id, notice.recipient, notice.event_type, notice.occasion);
        exception when others then
            update housemates_cleaning.notification_outbox set attempts = attempts + 1,
                next_attempt_at = p_now + make_interval(mins => 5 * (attempts + 1))
            where (turn_id, recipient, event_type, occasion) =
                  (notice.turn_id, notice.recipient, notice.event_type, notice.occasion);
            raise warning 'HouseMates cleaning notification enqueue failed (%)', sqlstate;
        end;
    end loop;
end;
$$;

-- Keep the existing schedule and stop legacy cleaning reminders when the new rotation starts.
create function housemates_cleaning.run_legacy_reminders(p_legacy_command text)
returns void language plpgsql set search_path = '' as $$
begin
    if not exists (
        select 1 from housemates_cleaning.settings
        where activation_week <= (now() at time zone 'Europe/Rome')::date
    ) then
        execute p_legacy_command;
    end if;
end;
$$;

revoke execute on function housemates_cleaning.turn_label(text), housemates_cleaning.note_completion(),
    housemates_cleaning.note_swap(),
    housemates_cleaning.run_notifications(timestamptz), housemates_cleaning.run_legacy_reminders(text)
    from public, anon, authenticated;

do $$
declare
    job record;
begin
    if to_regclass('cron.job') is null then return; end if;

    for job in select jobid, command from cron.job
        where jobname in ('promemoria-turni', 'promemoria-ritardi')
          and command not like 'select housemates_cleaning.run_legacy_reminders(%'
    loop
        perform cron.alter_job(job.jobid, command :=
            format('select housemates_cleaning.run_legacy_reminders(%L)', job.command));
    end loop;

    perform cron.schedule('housemates-cleaning-v2', '* * * * *',
        'select housemates_cleaning.run_notifications(now())');
end;
$$;

commit;
