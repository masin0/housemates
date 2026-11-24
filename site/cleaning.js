const cleaningUI = (() => {
  const rooms = {
    bagno: 'Bagno', cucina: 'Cucina', corridoio: 'Corridoio', balcone: 'Balcone'
  };
  const kinds = {
    'mer-bagno': { name: 'Bagno infrasettimanale', room: 'bagno', days: [2, 3], icon: '🛁' },
    'we-bagno': { name: 'Bagno del weekend', room: 'bagno', days: [5, 6], icon: '🛁' },
    'we-cucina': { name: 'Cucina', room: 'cucina', days: [5, 6], icon: '🍽️' },
    'we-corridoio': { name: 'Corridoio', room: 'corridoio', days: [5, 6], icon: '🚪' },
    balcone: { name: 'Balcone', room: 'balcone', icon: '🪴' }
  };
  const labels = {
    choose_day: 'Da scegliere', scheduled: 'Programmato', completed: 'Completato',
    recovery: 'Da recuperare', suspended: 'Sospeso per ferie'
  };
  const timeZone = 'Europe/Rome';
  const isoFormat = new Intl.DateTimeFormat('sv-SE', { timeZone });
  const dayFormat = new Intl.DateTimeFormat('it-IT', { weekday: 'long', timeZone });
  const dateFormat = new Intl.DateTimeFormat('it-IT', { weekday: 'long', day: 'numeric', month: 'long', timeZone });
  const completionFormat = new Intl.DateTimeFormat('it-IT', {
    day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone
  });
  const pendingReads = new Map();
  const rendered = new WeakMap();
  let celebrating = null;
  let working = false;

  const romeToday = () => isoFormat.format(new Date());
  const currentWeek = () => mondayOf(romeToday());
  const viewWeek = () => addDays(currentWeek(), 7 * (tab === 'faccende' ? weekOff : 0));
  const asDate = iso => new Date(`${iso}T12:00:00Z`);
  const dayName = iso => cap(dayFormat.format(asDate(iso)));
  const dateName = iso => cap(dateFormat.format(asDate(iso)));
  const button = (label, action, tone = '') =>
    `<button type="button" class="cleaning-btn ${tone}" data-a="${esc(action)}">${esc(label)}</button>`;

  function paint(container, markup) {
    const previous = rendered.get(container);
    if (previous?.markup === markup && previous.first === container.firstChild) return;
    const active = document.activeElement;
    const focus = container.contains(active) ? active?.dataset?.a : null;
    const focusDetails = container.contains(active) ? active?.closest('details')?.dataset.turnId : null;
    const open = new Set([...container.querySelectorAll('details[open]')].map(detail => detail.dataset.turnId));
    container.innerHTML = markup;
    rendered.set(container, { markup, first: container.firstChild });
    for (const detail of container.querySelectorAll('details')) {
      detail.open = open.has(detail.dataset.turnId);
      if (focusDetails === detail.dataset.turnId) detail.querySelector('summary')?.focus();
    }
    if (focus) [...container.querySelectorAll('[data-a]')].find(element => element.dataset.a === focus)?.focus();
  }

  function read(week = currentWeek()) {
    if (!me || isGuest() || pending) return Promise.resolve({ data: null, error: null });
    const key = `${me.id}|${week}`;
    if (!pendingReads.has(key)) {
      const result = Promise.resolve(sb.rpc('cleaning_snapshot', { p_week: week }))
        .then(({ data, error }) => {
          if (error?.code === 'PGRST202' && /cleaning_snapshot/.test(error.message)) {
            return { data: null, error: null };
          }
          return { data, error };
        })
        .catch(error => ({ data: null, error }))
        .finally(() => pendingReads.delete(key));
      pendingReads.set(key, result);
    }
    return pendingReads.get(key);
  }

  function instructions(steps) {
    return `<ul class="cleaning-steps">${(steps || []).map(step => `<li>${esc(step)}</li>`).join('')}</ul>`;
  }

  function dateChoices(turn) {
    const eligible = turn.eligible_dates || [];
    const typical = turn.status === 'recovery' ? eligible : kinds[turn.kind]?.days?.map(n => addDays(turn.week, n)) || eligible;
    return typical.map(date => {
      const allowed = eligible.includes(date);
      const unavailable = `disabled aria-label="${esc(dayName(date))}, non disponibile"`;
      return `<button type="button" class="cleaning-btn" ${allowed ? `data-a="clean:day,${esc(turn.id)},${date}"` : unavailable}>${esc(dayName(date))}</button>`;
    }).join('');
  }

  function dateLine(turn) {
    if (turn.status === 'completed' && turn.completed_at) {
      return completionFormat.format(new Date(turn.completed_at));
    }
    if (turn.chosen_date) return dateName(turn.chosen_date);
    const eligible = turn.eligible_dates?.length ? turn.eligible_dates
      : turn.status === 'choose_day' ? kinds[turn.kind]?.days?.map(day => addDays(turn.week, day)) || [] : [];
    if (eligible.length) return eligible.map(dayName).join(' o ');
    return '';
  }

  function canSwap(turn) {
    return turn.can_swap ?? ['choose_day', 'scheduled'].includes(turn.status);
  }

  function turnCard(turn, snapshot, home = false) {
    const kind = kinds[turn.kind];
    if (!kind) return '';
    const mine = turn.assignee === me.id;
    const label = turn.confirm_due ? 'In attesa di conferma' : labels[turn.status];
    const person = turn.status === 'completed' ? turn.completed_by || turn.assignee : turn.assignee;
    const detail = [home ? '' : (person && (mine && person === me.id ? 'Tocca a te' : nm(person))), dateLine(turn)]
      .filter(Boolean).join(' · ');
    const steps = instructions(snapshot.instructions?.[kind.room]);
    const open = turn.status !== 'completed' && turn.status !== 'suspended';
    const showInstructions = open && home && mine
      ? `<h4>Cosa devi fare</h4>${steps}`
      : `<details data-turn-id="${esc(turn.id)}"><summary>Istruzioni</summary>${steps}</details>`;
    const choices = mine && turn.eligible_dates?.length && ['choose_day', 'recovery'].includes(turn.status)
      ? turn.status === 'recovery'
        ? `<details data-turn-id="${esc(turn.id)}-recovery"><summary>Scegli un giorno per recuperare</summary><div class="cleaning-actions">${dateChoices(turn)}</div></details>`
        : `<div class="cleaning-choice"><p>Quando preferisci?</p><div class="cleaning-actions">${dateChoices(turn)}</div></div>` : '';
    const confirm = turn.confirm_due && mine && turn.can_complete
      ? `<div class="cleaning-choice"><p>Hai completato?</p><div class="cleaning-actions">${button('Sì', `clean:confirm,${turn.id},yes`, 'primary')}${button('No', `clean:confirm,${turn.id},no`)}</div></div>` : '';
    const done = mine && turn.can_complete && !turn.confirm_due ? button('Ho finito! ✨', `clean:finish,${turn.id}`, 'primary') : '';
    const pendingSwap = (snapshot.swaps || []).some(swap => swap.status === 'pending' &&
      (swap.turn_id === turn.id || swap.exchange_turn_id === turn.id));
    const ask = mine && canSwap(turn) && !pendingSwap ? button('Chiedi un cambio', `clean:swap,${turn.id}`) : '';
    const assign = !home && isAdmin() && canSwap(turn) ? button('Riassegna', `clean:assign,${turn.id}`) : '';
    return `<article class="cleaning-card ${turn.status === 'completed' ? 'is-complete' : ''} ${celebrating === turn.id ? 'celebrate' : ''}">
      <div class="cleaning-head"><span class="cleaning-icon" aria-hidden="true">${kind.icon}</span><div>
        <h3>${kind.name}</h3>${detail ? `<p class="cleaning-meta">${esc(detail)}</p>` : ''}</div></div>
      <div class="cleaning-badges"><span class="cleaning-status">${esc(label || '')}</span>
        ${turn.reassigned_at && open ? '<span class="cleaning-status">Riassegnato</span>' : ''}</div>
      ${choices}${showInstructions}${confirm}${done || ask || assign ? `<div class="cleaning-actions">${done}${ask}${assign}</div>` : ''}
    </article>`;
  }

  function pauseCard(snapshot) {
    return `<div class="cleaning-card cleaning-pause"><p class="cleaning-pause-title">Calma piatta... <span aria-hidden="true">🌴</span> Tutti in pausa!</p>
      ${snapshot.returns_on ? `<p class="cleaning-meta">Rientro previsto ${esc(dateName(snapshot.returns_on))}.</p>` : ''}</div>`;
  }

  function home(snapshot) {
    const weekTurns = snapshot.turns || [];
    const unique = new Map([...weekTurns, ...(snapshot.personal_open || [])].map(turn => [turn.id, turn]));
    const personal = [...unique.values()].filter(turn => turn.assignee === me.id && turn.status !== 'suspended');
    const pendingTurns = personal.filter(turn => turn.status !== 'completed');
    const complete = personal.filter(turn => turn.status === 'completed')
      .sort((a, b) => (b.completed_at || '').localeCompare(a.completed_at || ''));
    const cards = snapshot.paused ? [] : pendingTurns.length ? pendingTurns : complete.slice(0, 1);
    return `<div class="cleaning-stack">
      ${snapshot.paused ? pauseCard(snapshot) : ''}
      ${cards.map(turn => turnCard(turn, snapshot, true)).join('')}
      ${snapshot.paused || cards.length ? '' : '<div class="cleaning-card"><h3>Non hai pulizie in programma</h3></div>'}
      <div class="cleaning-actions">${button('Vedi tutti i turni', 'go:faccende')}${button('Ferie / Pausa', 'clean:absences')}</div>
    </div>`;
  }

  function calendar(snapshot) {
    const sorted = (snapshot.turns || []).filter(turn => kinds[turn.kind] && !['completed', 'suspended'].includes(turn.status))
      .map(turn => ({ turn, date: turn.chosen_date || turn.eligible_dates?.[0] || snapshot.today }))
      .sort((a, b) => a.date.localeCompare(b.date));
    return sorted.length ? sorted.map(({ turn, date }) => `<div class="cal-it ${turn.status === 'recovery' ? 'late' : ''}">
      <div class="cal-d"><span>${esc(dayName(date).slice(0, 3))}</span><b>${Number(date.slice(-2))}</b></div>
      <div class="cal-m"><div class="cal-t">${kinds[turn.kind].name}</div>
        <div class="cal-s">${esc(turn.assignee === me.id ? 'Tocca a te' : nm(turn.assignee))}${turn.chosen_date ? '' : ' · giorno da scegliere'}</div></div></div>`).join('')
      : '<p class="cal-empty">Niente in programma per ora.</p>';
  }

  function swapInbox(snapshot) {
    const visible = (snapshot.swaps || []).filter(swap => ['pending', 'accepted', 'declined'].includes(swap.status));
    if (!visible.length) return '';
    return `<section class="cleaning-stack" aria-label="Cambi turno">${visible.map(swap => {
      const incoming = swap.recipient === me.id;
      const other = incoming ? swap.requester : swap.recipient;
      const name = nm(other);
      const turn = (snapshot.turns || []).find(t => t.id === swap.turn_id);
      const kind = kinds[swap.kind || turn?.kind];
      const starts = swap.week || turn?.week;
      const exchange = kinds[swap.exchange_kind];
      const summary = [kind?.name || 'Richiesta di cambio turno', starts && dayMon(starts),
        exchange && `in cambio di ${exchange.name} del ${dayMon(swap.exchange_week)}`].filter(Boolean).join(' · ');
      const state = swap.status === 'pending' ? (incoming ? `${name} ti chiede un cambio` : `In attesa di ${name}`)
        : swap.status === 'accepted' ? 'Cambio accettato' : 'Cambio rifiutato';
      const pendingActions = incoming
        ? button('Accetta', `clean:reply,${swap.id},yes`, 'primary') + button('Rifiuta', `clean:reply,${swap.id},no`)
        : button('Ritira', `clean:cancel,${swap.id}`);
      return `<article class="cleaning-card"><h3>${esc(state)}</h3><p class="cleaning-meta">${esc(summary)}</p>
        ${swap.status === 'pending' ? `<div class="cleaning-actions">${pendingActions}</div>` : ''}</article>`;
    }).join('')}</section>`;
  }

  function week(snapshot) {
    const { week: mon } = snapshot;
    const label = weekOff === 0 ? 'Questa settimana' : weekOff === 1 ? 'Prossima settimana' : 'Settimana del';
    const min = firstCleaningWeekOffset();
    const turns = (snapshot.turns || []).filter(turn => turn.week === mon);
    const balcony = snapshot.balcony_pending ?? turns.some(turn => turn.kind === 'balcone' && turn.status !== 'completed');
    return `<div class="weeknav">
      <button class="nb" data-a="wk:-1" aria-label="Settimana precedente" ${weekOff <= min ? 'disabled' : ''}>${I.back}</button>
      <div class="wl" aria-live="polite"><b>${label}</b><span>${fmtDays(mon, addDays(mon, 6))}</span></div>
      <button class="nb" data-a="wk:1" aria-label="Settimana successiva" ${weekOff >= WEEK_MAX ? 'disabled' : ''}>${I.chev}</button></div>
      <div class="cleaning-stack">
        <div class="cleaning-actions">${button('Ferie / Pausa', 'clean:absences')}${button('Istruzioni di pulizia', 'clean:instructions')}
          ${weekOff === 0 && !balcony ? button('Segnala balcone sporco', 'clean:balcony') : ''}</div>
        ${snapshot.paused ? pauseCard(snapshot) : ''}${swapInbox(snapshot)}${turns.map(turn => turnCard(turn, snapshot)).join('')}
      </div>`;
  }

  async function send(action, payload = {}) {
    const { error } = await sb.rpc('cleaning_action', { p_action: action, p_payload: payload });
    if (error) throw error;
  }

  async function change(action, payload, message) {
    if (working) return;
    working = true;
    try {
      await send(action, payload);
      if (action === 'complete' || (action === 'confirm' && payload.answer)) {
        celebrating = payload.turn_id;
        const id = celebrating;
        setTimeout(() => { if (celebrating === id) celebrating = null; }, 2000);
      }
      toast(message);
      refresh();
      return true;
    } catch (error) {
      toast(`Errore: ${errMsg(error)}`);
    } finally {
      working = false;
    }
  }

  function renderAbsences(snapshot) {
    const periods = (snapshot.absences || []).filter(period => period.ends_on >= snapshot.today);
    openPanel('Ferie / Pausa', `<div class="cleaning-stack">${periods.map(period => `<div class="cleaning-card">
        <p>Dal ${esc(dateName(period.starts_on))}. Rientro il ${esc(dateName(addDays(period.ends_on, 1)))}.</p>
        <div class="cleaning-actions">${button('Modifica', `clean:absence-edit,${period.id}`)}${button('Annulla periodo', `clean:absence-delete,${period.id}`)}</div>
      </div>`).join('')}${periods.length ? '' : '<p>Nessuna assenza in programma.</p>'}
      ${button('Aggiungi un’assenza', 'clean:absence-edit', 'primary')}</div>`);
  }

  function absenceForm(snapshot, id) {
    const period = (snapshot.absences || []).find(entry => entry.id === id);
    const start = period?.starts_on || snapshot.today;
    const back = period ? addDays(period.ends_on, 1) : '';
    openModal(period ? 'Modifica assenza' : 'Aggiungi un’assenza',
      field('Inizio assenza', `<input type="date" name="start" required min="${esc(start < snapshot.today ? start : snapshot.today)}" value="${esc(start)}">`) +
      field('Data di rientro', `<input type="date" name="back" required value="${esc(back)}">`),
      'Salva', async form => {
        const starts_on = form.get('start'), returnOn = form.get('back');
        if (!starts_on || !returnOn || returnOn <= starts_on) throw new Error('Il rientro deve essere successivo all’inizio.');
        await send('absence_save', { id: period?.id, starts_on, ends_on: addDays(returnOn, -1) });
        toast('Assenza salvata');
      });
  }

  function showInstructions(snapshot) {
    openPanel('Istruzioni di pulizia', `<div class="cleaning-stack">${Object.entries(rooms).map(([room, name]) =>
      `<section class="cleaning-card"><h3>${name}</h3>${instructions(snapshot.instructions?.[room])}
        ${isAdmin() ? button('Modifica istruzioni', `clean:instruction-edit,${room}`) : ''}</section>`).join('')}</div>`);
  }

  function instructionForm(snapshot, room) {
    if (!isAdmin() || !rooms[room]) return;
    openModal(`Istruzioni · ${rooms[room]}`, field('Un passaggio per riga',
      `<textarea name="steps" rows="9" required>${esc((snapshot.instructions?.[room] || []).join('\n'))}</textarea>`), 'Salva', async form => {
      const steps = form.get('steps').split('\n').map(line => line.trim()).filter(Boolean);
      if (!steps.length) throw new Error('Inserisci almeno un passaggio.');
      await send('admin_instructions', { room, steps });
      toast('Istruzioni aggiornate');
    });
  }

  async function swapForm(snapshot, turn) {
    const otherWeeks = await Promise.all([read(addDays(snapshot.week, -7)), read(addDays(snapshot.week, 7))]);
    if (tab !== 'faccende' && tab !== 'home') return;
    const options = [snapshot, ...otherWeeks.map(response => response.data)].filter(Boolean)
      .flatMap(value => value.turns || []).filter(other => other.id !== turn.id && other.assignee !== me.id && other.assignee && canSwap(other));
    const candidates = profileList().filter(person => person.id !== me.id);
    if (!candidates.length) return toast('Non ci sono altri coinquilini a cui chiedere.');
    openModal(`Cambio turno · ${kinds[turn.kind].name}`,
      field('A chi vuoi chiedere?', `<select name="recipient">${candidates.map(person =>
        `<option value="${esc(person.id)}">${esc(person.nome)}</option>`).join('')}</select>`) +
      field('Come vuoi organizzarti?', '<select name="counterpart"></select>'), 'Invia richiesta', async form => {
        const recipient = form.get('recipient'), exchange_turn_id = form.get('counterpart') || undefined;
        await send('swap_request', { turn_id: turn.id, recipient, exchange_turn_id });
        toast('Cambio turno richiesto');
      });
    const recipient = $('#m-form [name="recipient"]'), select = $('#m-form [name="counterpart"]');
    const drawChoices = () => {
      select.innerHTML = '<option value="">Chiedi una sostituzione</option>' + options.filter(other => other.assignee === recipient.value)
        .map(other => `<option value="${esc(other.id)}">Scambia con ${esc(kinds[other.kind].name)}, ${esc(dayMon(other.week))}</option>`).join('');
    };
    recipient.addEventListener('change', drawChoices);
    drawChoices();
  }

  function assignForm(turn) {
    const options = profileList().filter(person => person.id !== turn.assignee).map(person =>
      `<option value="${esc(person.id)}">${esc(person.nome)}</option>`).join('');
    if (!options) return toast('Non ci sono altri coinquilini disponibili.');
    openModal(`Riassegna · ${kinds[turn.kind].name}`, field('Nuovo responsabile', `<select name="assignee">${options}</select>`),
      'Riassegna', async form => {
        await send('admin_assign', { turn_id: turn.id, assignee: form.get('assignee') });
        toast('Turno riassegnato');
      });
  }

  async function action(raw) {
    const [command, id, value] = raw.split(',');
    if (command === 'day') return change('choose_day', { turn_id: id, date: value }, 'Giorno salvato');
    if (command === 'finish') return change('complete', { turn_id: id }, 'Pulizia completata! ✨');
    if (command === 'confirm') return change('confirm', { turn_id: id, answer: value === 'yes' },
      value === 'yes' ? 'Pulizia completata! ✨' : 'Turno da recuperare');
    if (command === 'balcony') return change('report_balcony', {}, 'Balcone segnalato');
    if (command === 'reply') return change('swap_reply', { id, accept: value === 'yes' }, value === 'yes' ? 'Cambio accettato' : 'Cambio rifiutato');
    if (command === 'cancel') return change('swap_cancel', { id }, 'Richiesta ritirata');
    if (command === 'absence-delete') {
      return customConfirm('Annullare questo periodo di assenza?', async () => {
        if (await change('absence_delete', { id }, 'Assenza annullata')) closeModal();
      });
    }
    const { data, error } = await read(viewWeek());
    if (error || !data) return toast(error ? `Errore: ${errMsg(error)}` : 'I turni aggiornati non sono ancora disponibili.');
    if (command === 'absences') return renderAbsences(data);
    if (command === 'absence-edit') return absenceForm(data, id);
    if (command === 'instructions') return showInstructions(data);
    if (command === 'instruction-edit') return instructionForm(data, id);
    const turn = [...(data.turns || []), ...(data.personal_open || [])].find(entry => entry.id === id);
    if (!turn) return toast('Il turno è cambiato. Riapri la panoramica.');
    if (command === 'swap') return swapForm(data, turn);
    if (command === 'assign' && isAdmin()) return assignForm(turn);
  }

  return { currentWeek, read, paint, home, calendar, week, action };
})();
