// Minimal service worker — just enough to make the app installable.
// Deliberately network-first and narrow in scope: it never touches
// Supabase requests (bookings must always be live, never cached), and
// only caches the static app shell as a fallback for brief offline blips.
//
// OneSignal's push-notification handling is merged in here (rather than
// registered as its own separate OneSignalSDKWorker.js) because a page can
// only have one active service worker per scope — two competing
// registrations at "/" would fight over control instead of coexisting.
importScripts('https://cdn.onesignal.com/sdks/web/v16/OneSignalSDKWorker.js');

const CACHE_NAME = 'seaford-lax-shell-v2';
const SHELL_FILES = ['./', './index.html', './manifest.json', './offline.html'];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(SHELL_FILES)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(names =>
      Promise.all(names.filter(n => n !== CACHE_NAME).map(n => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // Never intercept Supabase (API, auth, realtime) — always go live to the network.
  if (url.hostname.includes('supabase.co')) return;
  // Only handle same-origin GET requests for the static shell.
  if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(event.request)
      .then(response => {
        const clone = response.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone)).catch(() => {});
        return response;
      })
      .catch(() =>
        caches.match(event.request).then(cached =>
          cached || (event.request.mode === 'navigate' ? caches.match('./offline.html') : undefined)
        )
      )
  );
});
