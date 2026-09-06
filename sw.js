// ══════════════════════════════════════════════════════════════════
// Fluxy ERP — Service Worker v2.0
// Strategy: Network-first for app shell (always latest app code),
//           cache fallback only when offline.
// Updates stay waiting until the user confirms via the app update bar.
// ══════════════════════════════════════════════════════════════════

var CACHE_VERSION    = '2.0';
var CACHE_NAME       = 'fluxy-v' + CACHE_VERSION;
var CACHE_OLD_PREFIX = 'fluxy-v';

// App shell — single-file architecture (all CSS/JS embedded in index.html).
// Do not pre-cache sw.js itself; the browser owns the service-worker update flow.
var SHELL_ASSETS = [
  './index.html',
  './manifest.json',
];

// ── Install: pre-cache shell ──────────────────────────────────────
self.addEventListener('install', function(e){
  e.waitUntil(
    caches.open(CACHE_NAME).then(function(cache){
      return cache.addAll(SHELL_ASSETS);
    })
  );
  // IMPORTANT: no automatic skipWaiting() here.
  // On updates, the new worker remains waiting until the user clicks
  // “Atualizar agora”, when the page sends {type:'SKIP_WAITING'}.
});

// ── Activate: delete old caches ───────────────────────────────────
self.addEventListener('activate', function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(
        keys.filter(function(k){
          return k.startsWith(CACHE_OLD_PREFIX) && k !== CACHE_NAME;
        }).map(function(k){ return caches.delete(k); })
      );
    }).then(function(){
      return self.clients.claim();
    })
  );
});

// ── Fetch: network-first for app code, cache fallback offline ─────
self.addEventListener('fetch', function(e){
  var url = e.request.url;

  // Only handle same-origin GET requests.
  if(e.request.method !== 'GET') return;
  if(!url.startsWith(self.location.origin)) return;

  // Never intercept API/auth calls.
  if(url.includes('/functions/') || url.includes('/auth/') || url.includes('/rest/')){
    return;
  }

  var isNavigation = (e.request.mode === 'navigate');
  var isAppShell = isNavigation ||
                   url.endsWith('/') ||
                   url.includes('index.html') ||
                   url.includes('manifest.json');

  if(isAppShell){
    // NETWORK-FIRST: always try latest version; cache only as offline fallback.
    e.respondWith(
      fetch(e.request).then(function(response){
        if(response && response.status === 200){
          var copy = response.clone();
          caches.open(CACHE_NAME).then(function(cache){ cache.put(e.request, copy); });
        }
        return response;
      }).catch(function(){
        return caches.match(e.request).then(function(cached){
          return cached || caches.match('./index.html');
        });
      })
    );
    return;
  }

  // Other same-origin assets: cache-first with background refresh.
  e.respondWith(
    caches.match(e.request).then(function(cached){
      var network = fetch(e.request).then(function(response){
        if(response && response.status === 200){
          var copy = response.clone();
          caches.open(CACHE_NAME).then(function(cache){ cache.put(e.request, copy); });
        }
        return response;
      }).catch(function(){ return cached; });
      return cached || network;
    })
  );
});

// ── Message: activate only after explicit user confirmation ───────
self.addEventListener('message', function(e){
  if(e.data && e.data.type === 'SKIP_WAITING'){
    self.skipWaiting();
  }
});
