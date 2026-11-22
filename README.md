# HouseMates V2 — app di casa Via Frejus

Web app (PWA) per i coinquilini: turni pulizie, bagno, spesa, soldi, bacheca, decisioni, ospiti.

- **Sito live:** https://frejusmates.netlify.app (Netlify, deploy automatico da `main`)
- **Backend:** Supabase, progetto `vbxxbxtknnxnodicvwsp`

## Struttura
```
site/                      → tutto quello che va online (Netlify pubblica questa cartella)
  index.html               → l'app intera (HTML + CSS + JS)
  manifest.json, sw.js     → PWA e notifiche push
  icon-*.png
supabase/
  functions/avvisi/        → Edge Function che invia le notifiche push
  sql/                     → script SQL già applicati (notifiche, bagno)
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

## Regole
- **Niente segreti nel repo.** La key `sb_publishable_…` nel codice è pubblica per design e va bene. La `service_role`, le chiavi VAPID private e `CASA_SECRET` stanno solo nei Secrets di Supabase (Edge Functions → Secrets).
- Modifiche al database: scrivi lo SQL in un nuovo file in `supabase/sql/` (es. `2026-11-23_nome.sql`), così l'altro sa cosa è cambiato.
- La versione dell'app si segna nei commit (es. `HOUSEMATES_V2_09_01: …`).
