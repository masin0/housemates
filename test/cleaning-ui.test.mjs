import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { createContext, runInContext } from 'node:vm';

const source = await readFile(new URL('../site/cleaning.js', import.meta.url), 'utf8');
const dateStamp = date => date.toISOString().slice(0, 10);
const addDays = (iso, days) => dateStamp(new Date(Date.parse(`${iso}T00:00:00Z`) + days * 86400000));

function setup(rpc = async () => ({ data: {}, error: null })) {
  let refreshed = 0;
  const ctx = createContext({
    me: { id: 'me' }, pending: false, isGuest: () => false, isAdmin: () => false,
    sb: { rpc }, esc: value => String(value ?? '').replaceAll('<', '&lt;'),
    nm: id => ({ me: 'Michele', other: 'Riccardo' })[id], addDays,
    mondayOf: iso => addDays(iso, -(new Date(`${iso}T00:00:00Z`).getUTCDay() + 6) % 7),
    cap: value => value[0].toUpperCase() + value.slice(1),
    fmtDays: (from, to) => `${from} – ${to}`, dayMon: date => date,
    firstCleaningWeekOffset: () => -10, weekOff: 0, WEEK_MAX: 8,
    I: { back: '‹', chev: '›' }, toast: () => {}, refresh: () => { refreshed++; }, setTimeout: () => {}
  });
  runInContext(source, ctx);
  return { ui: runInContext('cleaningUI', ctx), refreshes: () => refreshed };
}

const weekend = {
  id: 'hall', week: '2026-12-07', kind: 'we-corridoio', assignee: 'me',
  status: 'choose_day', eligible_dates: ['2026-12-13'], can_complete: false
};
const snapshot = {
  active: true, week: '2026-12-07', today: '2026-12-11',
  turns: [weekend], instructions: { corridoio: ['Riordina', 'Lava il pavimento'] }
};

test('Oggi mostra il turno personale, le istruzioni e la scelta consentita', () => {
  const { ui } = setup();
  const html = ui.home(snapshot);
  assert.match(html, /Corridoio/);
  assert.match(html, /<li>Riordina<\/li>/);
  assert.match(html, /disabled[^>]+Sabato/);
  assert.match(html, /clean:day,hall,2026-12-13[^>]*>Domenica/);
  assert.doesNotMatch(html, /checkbox|Ho finito/);
});

test('Oggi usa un solo pulsante per completare e conferma con Sì o No', () => {
  const { ui } = setup();
  const scheduled = { ...weekend, status: 'scheduled', chosen_date: '2026-12-13', can_complete: true };
  const ordinary = ui.home({ ...snapshot, turns: [scheduled] });
  assert.equal(ordinary.match(/Ho finito!/g).length, 1);
  const delayed = ui.home({ ...snapshot, turns: [], personal_open: [{ ...scheduled, confirm_due: true }] });
  assert.match(delayed, /Hai completato\?/);
  assert.match(delayed, /clean:confirm,hall,yes/);
  assert.match(delayed, /clean:confirm,hall,no/);
  assert.doesNotMatch(delayed, /Ho finito!/);
});

test('Turni mantiene bagno e corridoio distinti e mostra solo le azioni consentite', () => {
  const { ui } = setup();
  const bathroom = { ...weekend, id: 'bath', kind: 'we-bagno', assignee: 'other', can_complete: true };
  const html = ui.week({ ...snapshot, turns: [weekend, bathroom], balcony_pending: true });
  assert.match(html, /Bagno del weekend/);
  assert.match(html, /Riccardo/);
  assert.match(html, /Corridoio/);
  assert.match(html, /Settimana precedente/);
  assert.doesNotMatch(html, /clean:day,bath|clean:finish,bath|Segnala balcone sporco/);
});

test('Oggi mostra la pausa generale e il rientro senza azioni di pulizia', () => {
  const { ui } = setup();
  const html = ui.home({ ...snapshot, paused: true, returns_on: '2026-12-13' });
  assert.match(html, /Calma piatta/);
  assert.match(html, /Rientro previsto Domenica 13 dicembre/);
  assert.doesNotMatch(html, /clean:day/);
});

test('Un doppio tocco conferma il turno con una sola chiamata e aggiorna la schermata', async () => {
  const calls = [];
  const { ui, refreshes } = setup(async (name, args) => {
    calls.push({ name, action: args.p_action, id: args.p_payload.turn_id });
    return { data: { ok: true }, error: null };
  });
  await Promise.all([ui.action('finish,hall'), ui.action('finish,hall')]);
  assert.deepEqual(calls, [{ name: 'cleaning_action', action: 'complete', id: 'hall' }]);
  assert.equal(refreshes(), 1);
});

test('Il flusso storico si attiva solo quando manca la nuova funzione', async () => {
  const missing = { code: 'PGRST202', message: 'Could not find public.cleaning_snapshot' };
  const forbidden = { code: '42501', message: 'Permission denied' };
  const old = setup(async () => ({ data: null, error: missing }));
  assert.equal((await old.ui.read(snapshot.week)).error, null);
  const denied = setup(async () => ({ data: null, error: forbidden }));
  assert.equal((await denied.ui.read(snapshot.week)).error, forbidden);
});
