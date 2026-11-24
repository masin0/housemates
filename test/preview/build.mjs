import { cp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const preview = resolve(root, '.preview');
const assets = resolve(preview, 'preview-db');
const postgres = resolve(root, 'test/node_modules/@electric-sql/pglite/dist');

await cp(resolve(root, 'site'), preview, { recursive: true });
await mkdir(assets, { recursive: true });

const postgresFiles = await readdir(postgres);
await Promise.all(postgresFiles
  .filter((file) => /^(?:index\.js|chunk-.*\.js|initdb\.wasm|pglite\.(?:data|wasm))$/.test(file))
  .map((file) => cp(resolve(postgres, file), resolve(assets, file))));

const migrations = resolve(root, 'supabase/migrations');
const sqlFiles = (await readdir(migrations)).filter((file) => file.endsWith('.sql')).sort();
const database = await Promise.all([
  readFile(resolve(root, 'test/fixtures/supabase.sql'), 'utf8'),
  ...sqlFiles.map((file) => readFile(resolve(migrations, file), 'utf8')),
]);
await writeFile(resolve(preview, 'preview-sql.json'), JSON.stringify(database));
await cp(new URL('client.js', import.meta.url), resolve(preview, 'cleaning-preview.js'));

const htmlPath = resolve(preview, 'index.html');
const html = await readFile(htmlPath, 'utf8');
const hostedClient = /<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2"><\/script>/;
if (!hostedClient.test(html) || !html.includes('async function initNotif(){')) {
  throw new Error('Impossibile isolare la connessione Supabase della Deploy Preview.');
}

await writeFile(htmlPath, html
  .replace(hostedClient, '<script src="cleaning-preview.js"></script>')
  .replace(/^const (SUPABASE_URL|SUPABASE_KEY|VAPID_PUBLIC) = .*$/gm, "const $1 = '';")
  .replace('async function initNotif(){', 'async function initNotif(){ return;')
  .replace(/<body[^>]*>/, '$&\n<aside id="preview-notice" style="padding:.5rem 1rem;text-align:center;font:600 .8rem system-ui;background:#251b32;color:white">Anteprima pulizie · Dati di prova</aside>'));
