# HouseMates V2 — app di casa Via Frejus

Web app (PWA) per i coinquilini: turni pulizie, bagno, spesa, soldi, bacheca, decisioni, ospiti.

- **Sito live:** https://frejusmates.netlify.app (Netlify, deploy automatico da `main`)
- **Backend:** Supabase, progetto `vbxxbxtknnxnodicvwsp`

## Struttura
```
site/                      → tutto quello che va online (Netlify pubblica questa cartella)
  index.html               → l'app intera (HTML + CSS + JS)
  cleaning.js, cleaning.css → interfaccia della gestione pulizie
  manifest.json, sw.js     → PWA e notifiche push
  icon-*.png
supabase/
  functions/avvisi/        → Edge Function che invia le notifiche push
  sql/                     → script SQL già applicati (notifiche, bagno)
  migrations/              → migrazioni versionate della gestione pulizie
netlify.toml               → config Netlify
```

## Come si lavora in due
1. Prima di iniziare: `git pull`
2. Modifichi i file (di solito `site/index.html`)
3. Provi in locale: `npx serve site` e apri http://localhost:3000
4. Salvi e carichi:
   ```
   git add -A
   git commit -m "cosa hai cambiato"
   git push
   ```
5. Dopo ~30 secondi Netlify pubblica la nuova versione.

Per modifiche grosse meglio un branch: `git checkout -b nome-modifica`, push, poi Pull Request su GitHub → Netlify crea un'anteprima del sito prima del merge.

## Turni di pulizia

Le nuove assegnazioni sono conservate in `housemates_cleaning`. La Home e la sezione Turni le leggono tramite `cleaning_snapshot` e inviano le modifiche a `cleaning_action`. Le settimane precedenti alla data di attivazione continuano a leggere `chore_log`, `chore_swaps` e la vecchia rotazione.

### Verifica in locale

```bash
npm ci --prefix test
npm test --prefix test
node test/preview/build.mjs
python -m http.server 4388 --bind 127.0.0.1 --directory .preview
```

Apri `http://127.0.0.1:4388/` per provare le pulizie con i profili di prova. La Deploy Preview usa la stessa app e le stesse migrazioni in un PostgreSQL temporaneo nel browser. Ogni cambio di scheda dell'app conserva i dati della sessione di prova, mentre ricaricare la pagina ricrea il database. Le push della prova vengono registrate nella coda di test.

### Attivazione dopo la revisione

1. Applica le due migrazioni in ordine in un progetto Supabase di test. Verifica la coda con il vostro trasporto di test e controlla i job `housemates-cleaning-v2`, `promemoria-turni` e, se presente, `promemoria-ritardi`.
2. Dopo l'approvazione, applica le migrazioni al database online e pubblica il frontend. La data di attivazione parte vuota, quindi la rotazione classica continua a servire le settimane esistenti.
3. Concorda un lunedì futuro e imposta `activation_week` in `housemates_cleaning.settings` con il ruolo di gestione del database. Da quella settimana entrano in vigore i nuovi turni. Gli avvisi delle pulizie leggono le assegnazioni salvate e usano l'ora di Roma.
4. Controlla la prima settimana e verifica la consegna di una push sui dispositivi iscritti. La colonna `queued_at` indica che l'invio è stato affidato al trasporto, mentre `attempts` registra gli errori di accodamento.

## Regole
- **Niente segreti nel repo.** La key `sb_publishable_…` nel codice è pubblica per design e va bene. La `service_role`, le chiavi VAPID private e `CASA_SECRET` stanno solo nei Secrets di Supabase (Edge Functions → Secrets).
- Modifiche al database: scrivi lo SQL in un nuovo file in `supabase/sql/` (es. `2026-11-23_nome.sql`), così l'altro sa cosa è cambiato.
- La versione dell'app si segna nei commit (es. `HOUSEMATES_V2_09_01: …`).
