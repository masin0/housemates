import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const monday = '2027-01-04';
const mondayMorning = '2027-01-04T08:00:00Z';
const saturday = '2027-01-09';
const sunday = '2027-01-10';
const residents = [1, 2, 3, 4].map(profile);
const kinds = ['mer-bagno', 'we-bagno', 'we-cucina', 'we-corridoio'];
const fixture = await readFile(new URL('fixtures/supabase.sql', import.meta.url), 'utf8');
const migrations = await Promise.all([
  '20261124180000_cleaning_rotation.sql',
  '20261124180100_cleaning_notifications.sql',
].map(name => readFile(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8')));

function profile(n) {
  return `00000000-0000-4000-8000-00000000000${n}`;
}

function plus(date, days) {
  return new Date(Date.parse(date) + days * 86_400_000).toISOString().slice(0, 10);
}

async function database(t, { activationWeek = monday } = {}) {
  const db = new PGlite();
  t.after(() => db.close());
  await db.exec(fixture);
  for (const migration of migrations) {
    await db.exec(migration);
  }
  if (activationWeek) {
    await db.query('update housemates_cleaning.settings set activation_week = $1::date', [activationWeek]);
  }
  return db;
}

async function asUser(db, user, task) {
  await db.exec(user ? 'set role authenticated' : 'set role anon');
  try {
    return await withClaim(db, user, task);
  } finally {
    await db.exec('reset role');
  }
}

async function withClaim(db, user, task) {
  await db.query("select set_config('request.jwt.claim.sub', $1, false)", [user ?? '']);
  try {
    return await task();
  } finally {
    await db.query("select set_config('request.jwt.claim.sub', '', false)");
  }
}

async function snapshot(db, user = residents[0], week = monday, now = mondayMorning) {
  return withClaim(db, user, async () => {
    const { rows } = await db.query(
      'select housemates_cleaning.snapshot($1::date, $2::timestamptz) as result', [week, now],
    );
    return rows[0].result;
  });
}

async function action(db, user, name, payload, now = mondayMorning) {
  return withClaim(db, user, async () => {
    const { rows } = await db.query(
      'select housemates_cleaning.action($1, $2::jsonb, $3::timestamptz) as result',
      [name, JSON.stringify(payload), now],
    );
    return rows[0].result;
  });
}

async function runNotifications(db, now) {
  await db.query('select housemates_cleaning.run_notifications($1::timestamptz)', [now]);
}

function getTurn(plan, kind) {
  const turn = plan.turns.find(entry => entry.kind === kind);
  assert.ok(turn, `Missing room ${kind}`);
  return turn;
}

test('migration starts inactive and keeps legacy completion and unrelated cron data', async t => {
  const db = await database(t, { activationWeek: null });
  const before = await snapshot(db);
  assert.equal(before.active, false);
  assert.equal(before.enabled, false);
  assert.deepEqual(before.turns ?? [], []);
  await db.query('update housemates_cleaning.settings set activation_week = $1::date', [monday]);
  const legacy = await snapshot(db, residents[0], '2026-12-28');
  assert.equal(legacy.active, false);
  assert.deepEqual(legacy.turns ?? [], []);
  const { rows: logs } = await db.query('select turno, passi, completato_il, aggiornato_da from public.chore_log');
  assert.deepEqual(logs.map(({ turno, passi, completato_il, aggiornato_da }) => ({
    turno,
    passi,
    completato_il: new Date(completato_il).toISOString(),
    aggiornato_da,
  })), [{
    turno: 'we-bagno',
    passi: ['corridoio', 'wc'],
    completato_il: '2027-01-02T15:30:00.000Z',
    aggiornato_da: residents[1],
  }]);
  const { rows: jobs } = await db.query("select jobname, active from cron.job where jobname = 'frejus-unrelated-test'");
  assert.deepEqual(jobs, [{ jobname: 'frejus-unrelated-test', active: true }]);
  const { rows: cleaningJobs } = await db.query(
    "select jobname, command from cron.job where jobname <> 'frejus-unrelated-test' order by jobname",
  );
  assert.deepEqual(cleaningJobs.map(job => job.jobname), ['housemates-cleaning-v2', 'promemoria-ritardi', 'promemoria-turni']);
  assert.match(cleaningJobs[0].command, /run_notifications/);
  assert.ok(cleaningJobs.slice(1).every(job => job.command.includes('run_legacy_reminders')));
});

test('52 weeks persist four independent turns with distinct and equitable assignments', async t => {
  const db = await database(t);
  const seen = new Map(residents.map(id => [id, new Map(kinds.map(kind => [kind, 0]))]));
  for (let i = 0; i < 52; i += 1) {
    const week = plus(monday, i * 7);
    const now = `${week}T08:00:00Z`;
    const plan = await snapshot(db, residents[0], week, now);
    assert.equal(plan.active, true);
    assert.equal(plan.turns.length, 4);
    assert.deepEqual(plan.turns.map(turn => turn.kind).sort(), [...kinds].sort());
    assert.deepEqual(plan.turns.map(turn => turn.assignee).sort(), residents);
    for (const { assignee, kind } of plan.turns) {
      const counts = seen.get(assignee);
      counts.set(kind, counts.get(kind) + 1);
    }
    if (i === 0 || i === 51) {
      const other = await snapshot(db, residents[2], week, now);
      const shared = turns => turns.map(({ id, kind, assignee, status }) => ({ id, kind, assignee, status }));
      assert.deepEqual(shared(plan.turns), shared(other.turns));
      assert.ok(!plan.instructions.bagno.some(step => /corridoio/i.test(step)));
    }
  }
  for (const kind of kinds) {
    const counts = residents.map(id => seen.get(id).get(kind));
    assert.ok(Math.max(...counts) - Math.min(...counts) <= 2, `${kind}: ${counts}`);
  }
  const { rows } = await db.query('select count(*)::integer as turns from housemates_cleaning.turns');
  assert.equal(rows[0].turns, 52 * 4);
});

test('three, two, one and no available residents are respected and work resumes later', async t => {
  const db = await database(t);
  for (let available = 3; available >= 0; available -= 1) {
    const week = plus(monday, (4 - available) * 7);
    const now = `${week}T08:00:00Z`;
    for (const resident of residents.slice(available)) {
      await action(db, resident, 'absence_save', { starts_on: week, ends_on: plus(week, 6) }, now);
    }
    const plan = await snapshot(db, residents[0], week, now);
    if (available === 0) {
      assert.equal(plan.paused, true);
      assert.ok(plan.turns.every(turn => turn.status === 'suspended' && turn.assignee === null));
      continue;
    }
    assert.equal(plan.turns.length, 4);
    assert.deepEqual([...new Set(plan.turns.map(turn => turn.assignee))].sort(), residents.slice(0, available));
  }
  const resumed = plus(monday, 35);
  const next = await snapshot(db, residents[0], resumed, `${resumed}T08:00:00Z`);
  assert.equal(next.paused, false);
  assert.deepEqual(next.turns.map(turn => turn.assignee).sort(), residents);
});

test('day choice validates ownership and availability, persists across views, then completes exactly once', async t => {
  const db = await database(t);
  const initial = getTurn(await snapshot(db), 'we-corridoio');
  assert.deepEqual(initial.eligible_dates, [saturday, sunday]);
  const outsider = residents.find(id => id !== initial.assignee);
  await assert.rejects(action(db, outsider, 'choose_day', { turn_id: initial.id, date: saturday }));
  await assert.rejects(action(db, initial.assignee, 'choose_day', { turn_id: initial.id, date: '2027-01-08' }));
  await assert.rejects(action(db, initial.assignee, 'choose_day', { turn_id: initial.id, date: saturday }, `${sunday}T09:00:00Z`));
  await action(db, initial.assignee, 'absence_save', { starts_on: saturday, ends_on: saturday });
  const availability = getTurn(await snapshot(db, initial.assignee), 'we-corridoio');
  assert.deepEqual(availability.eligible_dates, [sunday]);
  await assert.rejects(action(db, initial.assignee, 'choose_day', { turn_id: initial.id, date: saturday }));
  await action(db, initial.assignee, 'choose_day', { turn_id: initial.id, date: sunday });
  const scheduled = getTurn(await snapshot(db, outsider), 'we-corridoio');
  assert.equal(scheduled.status, 'scheduled');
  assert.equal(scheduled.chosen_date, sunday);
  const completedAt = `${sunday}T11:30:00Z`;
  await assert.rejects(action(db, outsider, 'complete', { turn_id: initial.id }, completedAt));
  await action(db, initial.assignee, 'complete', { turn_id: initial.id }, completedAt);
  try {
    await action(db, initial.assignee, 'complete', { turn_id: initial.id }, `${sunday}T12:01:00Z`);
  } catch {
    // A rejected repeat is valid if completion and its timestamp are unchanged.
  }
  const done = getTurn(await snapshot(db, outsider, monday, completedAt), 'we-corridoio');
  assert.equal(done.status, 'completed');
  assert.equal(done.completed_by, initial.assignee);
  assert.equal(new Date(done.completed_at).toISOString(), new Date(completedAt).toISOString());
  await action(db, initial.assignee, 'absence_save', { starts_on: sunday, ends_on: sunday }, completedAt);
  assert.equal(getTurn(await snapshot(db, outsider, monday, completedAt), 'we-corridoio').status, 'completed');
});

test('a resident can change or remove their own absence and other residents cannot see or edit it', async t => {
  const db = await database(t);
  const owner = residents[0];
  const other = residents[1];
  await action(db, owner, 'absence_save', { starts_on: saturday, ends_on: sunday });
  const [absence] = (await snapshot(db, owner)).absences;
  assert.equal(absence.ends_on, sunday);
  assert.deepEqual((await snapshot(db, other)).absences, []);
  await assert.rejects(action(db, other, 'absence_delete', { id: absence.id }));
  await assert.rejects(action(db, other, 'absence_save', {
    id: absence.id, starts_on: sunday, ends_on: sunday,
  }));
  await action(db, owner, 'absence_save', { id: absence.id, starts_on: sunday, ends_on: sunday });
  assert.deepEqual((await snapshot(db, owner)).absences, [{ id: absence.id, starts_on: sunday, ends_on: sunday }]);
  await action(db, owner, 'absence_delete', { id: absence.id });
  assert.deepEqual((await snapshot(db, owner)).absences, []);
});

test('a balcony report creates one open assignment that is separate from the four weekly turns', async t => {
  const db = await database(t);
  await action(db, residents[0], 'report_balcony', {});
  try {
    await action(db, residents[1], 'report_balcony', {});
  } catch {
    // A rejected duplicate is valid if the existing request is retained.
  }
  const plan = await snapshot(db);
  const balcony = getTurn(plan, 'balcone');
  assert.equal(plan.turns.length, 5);
  assert.ok(residents.includes(balcony.assignee));
  assert.deepEqual(plan.instructions.balcone, ['Riordinare.', 'Spazzare.', 'Lavare il pavimento.']);
  assert.deepEqual(balcony.eligible_dates, [saturday, sunday]);
  const { rows } = await db.query("select count(*)::integer as n from housemates_cleaning.turns where kind = 'balcone'");
  assert.equal(rows[0].n, 1);
});

test('accepted exchanges update both persistent assignments and reject an unrelated responder', async t => {
  const db = await database(t);
  const plan = await snapshot(db);
  const first = getTurn(plan, 'we-corridoio');
  const second = getTurn(plan, 'we-cucina');
  const outsider = residents.find(id => id !== first.assignee && id !== second.assignee);
  await action(db, first.assignee, 'swap_request', {
    turn_id: first.id,
    recipient: second.assignee,
    exchange_turn_id: second.id,
  });
  const pending = (await snapshot(db, second.assignee)).swaps.find(swap => swap.turn_id === first.id);
  assert.ok(pending);
  await assert.rejects(action(db, outsider, 'swap_reply', { id: pending.id, accept: true }));
  await action(db, second.assignee, 'swap_reply', { id: pending.id, accept: true });
  const updated = await snapshot(db);
  assert.equal(getTurn(updated, first.kind).assignee, second.assignee);
  assert.equal(getTurn(updated, second.kind).assignee, first.assignee);
  assert.ok(getTurn(updated, first.kind).reassigned_at);

  await action(db, outsider, 'absence_save', { starts_on: saturday, ends_on: sunday });
  await assert.rejects(action(db, second.assignee, 'swap_request', { turn_id: first.id, recipient: outsider }));
  const substitute = residents.find(id => ![first.assignee, second.assignee, outsider].includes(id));
  await action(db, second.assignee, 'swap_request', { turn_id: first.id, recipient: substitute });
  const request = (await snapshot(db, substitute)).swaps.find(swap => swap.status === 'pending');
  await action(db, substitute, 'swap_reply', { id: request.id, accept: false });
  assert.equal(getTurn(await snapshot(db), first.kind).assignee, second.assignee);
  const { rows: notices } = await db.query(`select event_type, recipient, title
    from housemates_cleaning.notification_outbox where turn_id = $1 order by event_type, title`, [first.id]);
  assert.deepEqual(notices.filter(notice => notice.event_type === 'swap_reply'), [
    { event_type: 'swap_reply', recipient: first.assignee, title: 'Cambio turno accettato' },
    { event_type: 'swap_reply', recipient: second.assignee, title: 'Cambio turno rifiutato' },
  ]);
  assert.deepEqual(notices.filter(notice => notice.event_type === 'swap_request').map(notice => notice.recipient).sort(),
    [second.assignee, substitute].sort());
});

test('guests and pending profiles cannot mutate cleaning, with admin changes restricted to admins', async t => {
  const db = await database(t);
  await assert.rejects(asUser(db, null, () => db.query("select public.cleaning_action('report_balcony', '{}'::jsonb)")));
  await assert.rejects(asUser(db, profile(5), () => db.query("select public.cleaning_action('report_balcony', '{}'::jsonb)")));
  await assert.rejects(action(db, profile(5), 'report_balcony', {}));
  await assert.rejects(action(db, profile(6), 'absence_save', { starts_on: monday, ends_on: monday }));
  await assert.rejects(action(db, residents[2], 'admin_instructions', { room: 'corridoio', steps: ['Modifica non autorizzata'] }));
  await action(db, residents[0], 'admin_instructions', { room: 'corridoio', steps: ['Riordinare.', 'Pulire gli angoli.'] });
  assert.deepEqual((await snapshot(db, residents[3])).instructions.corridoio, ['Riordinare.', 'Pulire gli angoli.']);
  await assert.rejects(asUser(db, residents[1], () => db.query("update housemates_cleaning.turns set status = 'completed'")));
  await assert.rejects(asUser(db, residents[1], () =>
    db.query("select housemates_cleaning.action('report_balcony', '{}'::jsonb, now())")));
  const { rows } = await asUser(db, residents[1], () =>
    db.query("select public.cleaning_snapshot('2026-12-28') as result"));
  assert.equal(rows[0].result.active, false);
});

test('choice notices run at 19:00 Rome in winter and summer with one delivery per recipient', async t => {
  const db = await database(t);
  const hallway = getTurn(await snapshot(db), 'we-corridoio');
  await runNotifications(db, '2027-01-05T17:59:00Z');
  const count = async () => Number((await db.query('select count(*) as n from test_support.push_requests')).rows[0].n);
  assert.equal(await count(), 0);
  await runNotifications(db, '2027-01-05T18:00:00Z');
  await runNotifications(db, '2027-01-05T18:01:00Z');
  assert.equal(await count(), 1);

  await action(db, hallway.assignee, 'absence_save', { starts_on: '2027-01-08', ends_on: '2027-01-08' });
  await runNotifications(db, '2027-01-08T17:59:00Z');
  assert.equal(await count(), 1);
  await runNotifications(db, '2027-01-08T18:00:00Z');
  assert.equal(await count(), 3);
  await runNotifications(db, '2027-01-09T07:00:00Z');
  assert.equal(await count(), 4);
  const { rows: weekend } = await db.query(
    "select recipient, event_type, queued_at from housemates_cleaning.notification_outbox where turn_id = $1",
    [hallway.id],
  );
  assert.equal(weekend.length, 1);
  assert.equal(weekend[0].recipient, hallway.assignee);
  assert.equal(weekend[0].event_type, 'choose');
  assert.equal(new Date(weekend[0].queued_at).toISOString(), '2027-01-09T07:00:00.000Z');

  const summerWeek = '2027-06-07';
  await snapshot(db, residents[0], summerWeek, `${summerWeek}T09:00:00Z`);
  await runNotifications(db, '2027-06-08T16:59:00Z');
  const before = await count();
  await runNotifications(db, '2027-06-08T17:00:00Z');
  await runNotifications(db, '2027-06-08T17:01:00Z');
  assert.equal(await count(), before + 1);
});

test('23:00 asks for confirmation without assuming No, then a No permits later recovery', async t => {
  const db = await database(t);
  const turn = getTurn(await snapshot(db), 'mer-bagno');
  await action(db, turn.assignee, 'choose_day', { turn_id: turn.id, date: '2027-01-06' });
  await runNotifications(db, '2027-01-06T21:59:00Z');
  await assert.rejects(action(db, turn.assignee, 'confirm', { turn_id: turn.id, answer: true }, '2027-01-06T21:59:00Z'));
  const { rows: reminders } = await db.query(
    'select recipient, event_type, occasion::text from housemates_cleaning.notification_outbox where turn_id = $1',
    [turn.id],
  );
  assert.deepEqual(reminders, [{ recipient: turn.assignee, event_type: 'reminder', occasion: '2027-01-06' }]);
  const before = await db.query('select count(*)::integer as n from test_support.push_requests');
  await runNotifications(db, '2027-01-06T22:00:00Z');
  await runNotifications(db, '2027-01-06T22:02:00Z');
  const after = await db.query('select count(*)::integer as n from test_support.push_requests');
  assert.equal(after.rows[0].n, before.rows[0].n + 1);
  const following = '2027-01-07T08:00:00Z';
  const awaiting = getTurn(await snapshot(db, turn.assignee, monday, following), turn.kind);
  assert.equal(awaiting.status, 'scheduled');
  assert.equal(awaiting.confirm_due, true);
  await action(db, turn.assignee, 'confirm', { turn_id: turn.id, answer: false }, following);
  assert.equal(getTurn(await snapshot(db, turn.assignee, monday, following), turn.kind).status, 'recovery');
  await action(db, turn.assignee, 'complete', { turn_id: turn.id }, following);
  await runNotifications(db, following);
  await runNotifications(db, '2027-01-07T08:01:00Z');
  const { rows: deliveries } = await db.query('select recipients, body from test_support.push_requests');
  const owner = ['Alice', 'Bruno', 'Carla', 'Dario'][residents.indexOf(turn.assignee)];
  const completion = deliveries.filter(({ body }) => body.includes(owner) && /completat|pulit/i.test(body));
  assert.deepEqual(completion.flatMap(row => row.recipients).sort(), residents.filter(id => id !== turn.assignee));
});

test('a missed push does not block the Yes confirmation flow or a persisted completion', async t => {
  const db = await database(t);
  const turn = getTurn(await snapshot(db), 'we-cucina');
  const chosen = { turn_id: turn.id, date: sunday };
  await action(db, turn.assignee, 'choose_day', chosen);
  const now = `${sunday}T22:01:00Z`;
  assert.equal(getTurn(await snapshot(db, turn.assignee, monday, now), turn.kind).confirm_due, true);
  await action(db, turn.assignee, 'confirm', { turn_id: turn.id, answer: true }, now);
  const completed = getTurn(await snapshot(db, turn.assignee, monday, now), turn.kind);
  assert.equal(completed.status, 'completed');
  const { rows: outbox } = await db.query(
    'select event_type, queued_at from housemates_cleaning.notification_outbox where turn_id = $1',
    [turn.id],
  );
  assert.deepEqual(outbox, Array(3).fill({ event_type: 'completed', queued_at: null }));
});
