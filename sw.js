// ══════════════════════════════════════════════════════════════════
// Fluxy ERP — Service Worker retirement v2.3
// Staging is online-only: Supabase/PostgreSQL is the source of truth.
// This worker exists only to retire caches created by older deployments.
// ══════════════════════════════════════════════════════════════════

var CACHE_OLD_PREFIX = 'fluxy-v';

// ── Install: pre-cache shell ──────────────────────────────────────
self.addEventListener('install', function(e){
  self.skipWaiting();
});

// ── Activate: delete old caches ───────────────────────────────────
self.addEventListener('activate', function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(
        keys.filter(function(k){ return k.startsWith(CACHE_OLD_PREFIX); })
          .map(function(k){ return caches.delete(k); })
      );
    }).then(function(){
      return self.clients.claim();
    })
  );
});

// ── Fetch: network only; never serve ERP data or shell offline ────
self.addEventListener('fetch', function(e){
  e.respondWith(fetch(e.request));
});

// ── Message: activate only after explicit user confirmation ───────
self.addEventListener('message', function(e){
  if(e.data && e.data.type === 'SKIP_WAITING'){
    self.skipWaiting();
  }
});
