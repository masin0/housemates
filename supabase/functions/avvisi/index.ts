// Edge Function "avvisi" — spedisce le notifiche push ai telefoni iscritti.
// Segreti richiesti: VAPID_PUBLIC, VAPID_PRIVATE, VAPID_SUBJECT, CASA_SECRET.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
webpush.setVapidDetails(
  Deno.env.get('VAPID_SUBJECT')!,
  Deno.env.get('VAPID_PUBLIC')!,
  Deno.env.get('VAPID_PRIVATE')!
);

Deno.serve(async (req) => {
  if (req.headers.get('x-casa-secret') !== Deno.env.get('CASA_SECRET')) {
    return new Response('non autorizzato', { status: 401 });
  }
  const { uids = [], title = 'Casa', body = '', tag = 'casa', url = './' } = await req.json().catch(() => ({}));
  if (!uids.length) return Response.json({ inviate: 0 });

  const { data, error } = await sb.from('push_subs').select('*').in('user_id', uids);
  if (error) return Response.json({ errore: error.message }, { status: 500 });

  const payload = JSON.stringify({ title, body, tag, url });
  const scaduti: string[] = [];
  let inviate = 0;

  await Promise.all((data ?? []).map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload
      );
      inviate++;
    } catch (e: any) {
      if (e?.statusCode === 404 || e?.statusCode === 410) scaduti.push(s.endpoint);
    }
  }));

  if (scaduti.length) await sb.from('push_subs').delete().in('endpoint', scaduti);
  return Response.json({ inviate, rimossi: scaduti.length });
});
