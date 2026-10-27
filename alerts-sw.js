// Emberline Alerts: shows the push notifications the player function sends (1v1 invites, new followers)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch(_) { d = { body: e.data ? e.data.text() : '' }; }
  const from = (d.data && d.data.from) || '';
  e.waitUntil(self.registration.showNotification(d.title || 'Emberline', { body: d.body || '', icon: 'alerts-icon.png', badge: 'alerts-icon.png', tag: d.kind ? d.kind + ':' + from : undefined, data: d }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(ws => { const w = ws.find(x => 'focus' in x); if (w){ w.navigate && w.navigate('alerts.html?open=1'); return w.focus(); } return self.clients.openWindow('alerts.html?open=1'); }));
});
