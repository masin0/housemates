// Loaded by the Deploy Preview only. This client keeps every read and write in the browser.
(() => {
  const alice = '00000000-0000-4000-8000-000000000001';
  const authListeners = [];
  const ready = Promise.all([import('./preview-db/index.js'), fetch('./preview-sql.json')])
    .then(async ([{ PGlite }, response]) => {
      if (!response.ok) throw new Error('Dati di prova non disponibili.');
      const db = new PGlite();
      for (const sql of await response.json()) await db.exec(sql);
      await db.exec(`update housemates_cleaning.settings
        set activation_week = date_trunc('week', now() at time zone 'Europe/Rome')::date`);
      return db;
    });
  ready.catch((error) => window.addEventListener('DOMContentLoaded', () => {
    document.querySelector('#preview-notice').textContent = error.message;
  }));

  let profileId = alice;
  const user = () => ({ id: profileId, is_anonymous: false });
  const okay = (data) => ({ data, error: null });
  const failure = (error) => ({ data: null, error: { message: error.message, code: error.code } });

  function previewQuery(table) {
    const filters = [];
    let singleton = false;
    const chain = {
      select: () => chain,
      order: () => chain,
      lte: () => chain,
      gte: () => chain,
      gt: () => chain,
      lt: () => chain,
      neq: () => chain,
      or: () => chain,
      not: () => chain,
      is: () => chain,
      in: () => chain,
      limit: () => chain,
      eq: (column, value) => { filters.push([column, value]); return chain; },
      maybeSingle: () => { singleton = true; return chain; },
      single: () => { singleton = true; return chain; },
      then: (resolve, reject) => ready.then(async (db) => {
        const rows = table === 'profiles'
          ? (await db.query("select * from public.profiles where stato = 'coinquilino' order by nome")).rows
          : [];
        const selected = rows.filter((row) => filters.every(([column, value]) => row[column] === value));
        return okay(singleton ? selected[0] || null : selected);
      }).catch(failure).then(resolve, reject),
    };
    const unsupported = async () => failure(new Error('In questa anteprima si possono provare le pulizie.'));
    return { ...chain, insert: unsupported, update: unsupported, upsert: unsupported, delete: unsupported };
  }

  async function rpc(name, params) {
    if (!['cleaning_snapshot', 'cleaning_action'].includes(name)) {
      return failure({ code: 'PGRST202', message: 'Funzione non inclusa nell’anteprima pulizie.' });
    }
    try {
      const db = await ready;
      const actor = profileId;
      return await db.transaction(async (tx) => {
        await tx.exec('set local role authenticated');
        await tx.query("select set_config('request.jwt.claim.sub', $1, true)", [actor]);
        const result = name === 'cleaning_snapshot'
          ? await tx.query('select public.cleaning_snapshot($1::date) as value', [params.p_week])
          : await tx.query('select public.cleaning_action($1::text, $2::jsonb) as value',
              [params.p_action, JSON.stringify(params.p_payload)]);
        return okay(result.rows[0].value);
      });
    } catch (error) {
      return failure(error);
    }
  }

  const auth = {
    getSession: async () => { await ready; return okay({ session: { user: user() } }); },
    onAuthStateChange: (listener) => authListeners.push(listener),
    signOut: async () => { authListeners.forEach((listener) => listener('SIGNED_OUT')); return okay(null); },
    signInWithPassword: async () => okay({ user: user() }),
    signInAnonymously: async () => okay({ user: user() }),
    signUp: async () => okay({ user: user(), session: true }),
  };
  window.supabase = {
    createClient: () => ({
      auth, from: previewQuery, rpc,
      channel: () => {
        const channel = { on: () => channel, subscribe: () => channel };
        return channel;
      },
      removeChannel: () => {},
    }),
  };

  window.addEventListener('DOMContentLoaded', async () => {
    try {
      const db = await ready;
      const { rows } = await db.query("select id, nome from public.profiles where stato = 'coinquilino' order by nome");
      const picker = document.createElement('select');
      picker.setAttribute('aria-label', 'Coinquilino di prova');
      for (const { id, nome } of rows) picker.add(new Option(nome, id, id === profileId, id === profileId));
      picker.addEventListener('change', () => {
        profileId = picker.value;
        window.enterApp(user());
      });
      document.querySelector('#preview-notice').append(' ', picker);
    } catch (error) {
      document.querySelector('#preview-notice').textContent = 'Impossibile aprire l’anteprima pulizie.';
      console.error(error);
    }
  });
})();
