// ══════════════════════════════════════════════════════════════════
// Fluxy ERP — Service Worker v1.3
// Strategy: Network-first for index.html (always latest app code),
//           cache fallback only when offline.
// Single-file architecture: index.html contains all CSS + JS inline
// ══════════════════════════════════════════════════════════════════

var CACHE_VERSION    = '1.4';
var CACHE_NAME       = 'fluxy-v' + CACHE_VERSION;
var CACHE_OLD_PREFIX = 'fluxy-v';

// App shell — single-file architecture (all CSS/JS embedded in index.html)
var SHELL_ASSETS = [
  './index.html',
  './sw.js',
  './manifest.json',
];

// ── Install: pre-cache shell ──────────────────────────────────────
self.addEventListener('install', function(e){
  e.waitUntil(
    caches.open(CACHE_NAME).then(function(cache){
      return cache.addAll(SHELL_ASSETS);
    }).then(function(){
      return self.skipWaiting(); // activate immediately
    })
  );
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
      return self.clients.claim(); // take control immediately
    })
  );
});

// ── Fetch: network-first for app code, cache fallback offline ─────
self.addEventListener('fetch', function(e){
  var url = e.request.url;

  // Only handle same-origin GET requests
  if(e.request.method !== 'GET') return;
  if(!url.startsWith(self.location.origin)) return;

  // Never intercept API/auth calls (Supabase etc. são cross-origin,
  // mas garantimos que qualquer rota dinâmica vá sempre à rede)
  if(url.includes('/functions/') || url.includes('/auth/') || url.includes('/rest/')){
    return; // deixa o navegador buscar direto da rede
  }

  var isNavigation = (e.request.mode === 'navigate');
  var isAppShell = isNavigation ||
                   url.endsWith('/') ||
                   url.includes('index.html') ||
                   url.includes('sw.js') ||
                   url.includes('manifest.json');

  if(isAppShell){
    // NETWORK-FIRST: sempre tenta a versão mais recente; cache só offline.
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

  // Demais assets: cache-first com atualização em segundo plano
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

// ── Message: force skip waiting ───────────────────────────────────
self.addEventListener('message', function(e){
  if(e.data && e.data.type === 'SKIP_WAITING'){
    self.skipWaiting();
  }
});
