// Keeps a copy of the app on the phone so it opens without signal.
// Always tries the network first, so updates show up when online.
const CACHE = 'kennel-v48';
const FILES = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES))); self.skipWaiting(); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))); self.clients.claim(); });
self.addEventListener('fetch', e => {
  // only the app's own files; the online copy (Supabase) always goes straight to the network
  if(e.request.method !== 'GET' || new URL(e.request.url).origin !== location.origin) return;
  e.respondWith(fetch(e.request).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; })
    .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html'))));
});

// New-request notifications (sent by the request-spot server function)
self.addEventListener('push', e => {
  let d = {}; try { d = e.data.json(); } catch(err) { d = {title:'Little Village Pet Lodge', body:e.data ? e.data.text() : ''}; }
  e.waitUntil(Promise.all([
    self.registration.showNotification(d.title || 'New request', {body:d.body || '', icon:'./icon-192.png', badge:'./icon-192.png', tag:d.tag || 'request', data:{url:d.url || './?tab=reqs'}}),
    // an open app reloads its requests right away
    clients.matchAll({type:'window', includeUncontrolled:true}).then(ws => ws.forEach(w => w.postMessage({type:'request'})))]));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL(e.notification.data && e.notification.data.url || './?tab=reqs', self.registration.scope).href;
  e.waitUntil(clients.matchAll({type:'window', includeUncontrolled:true}).then(ws => {
    const w = ws.find(x => x.url.startsWith(self.registration.scope));
    return w ? w.focus().then(x => x.navigate(url)) : clients.openWindow(url);
  }));
});
