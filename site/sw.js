/* Service worker: riceve le notifiche push e le mostra, anche ad app chiusa.
   Non mette niente in cache, così l'app è sempre aggiornata. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Via Frejus', {
    body: d.body || '', tag: d.tag || 'casa', lang: 'it',
    icon: 'icon-192.png', badge: 'icon-192.png', data: { url: d.url || './' }
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil(self.clients.matchAll({ type:'window', includeUncontrolled:true }).then(cs => {
    for (const c of cs) if ('focus' in c) return c.focus();
    if (self.clients.openWindow) return self.clients.openWindow(url);
  }));
});
