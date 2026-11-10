// Minimal service worker — just enough to make the app installable.
// Deliberately network-first and narrow in scope: it never touches
// Supabase requests (bookings must always be live, never cached), and
// only caches the static app shell as a fallback for brief offline blips.
//
// OneSignal's push-notification handling is merged in here (rather than
// registered as its own separate OneSignalSDKWorker.js) because a page can
// only have one active service worker per scope — two competing
// registrations at "/" would fight over control instead of coexisting.
//
// A blocked or unreachable CDN must not stop the offline shell installing
// (an uncaught importScripts error fails the whole worker). The cost: a
// worker that installed without OneSignal has no push handlers until the
// next version of this file installs.
try {
  importScripts('https://cdn.onesignal.com/sdks/web/v16/OneSignalSDKWorker.js');
} catch (err) { /* no push in this worker; the shell still works */ }

const CACHE_NAME = 'seaford-lax-shell-v5';
// The page draws nothing without its scripts, so they're part of the shell.
const SHELL_FILES = ['./', './index.html', './manifest.json', './offline.html',
  './vendor/supabase-2.117.1.js', './vendor/gsap-3.12.5.min.js', './vendor/Flip-3.12.5.min.js',
  './ui/spring.js', './ui/field-menu.js', './ui/aurora.js', './ui/ripple.js', './ui/sheet.js',
  './lib/field-catalog.js', './lib/league-sheet.js'];

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
        // Keep good answers only, and only under the file's own address. A
        // 404 used to be stored as the fallback, and every ?v= / ?fixture=
        // variant of the page was kept as one more copy of it.
        if (response.ok && !url.search) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone)).catch(() => {});
        }
        return response;
      })
      .catch(() =>
        // ignoreSearch: offline, /?anything is answered by the stored page.
        caches.match(event.request, { ignoreSearch: true }).then(cached =>
          cached || (event.request.mode === 'navigate' ? caches.match('./offline.html') : undefined)
        )
      )
  );
});
