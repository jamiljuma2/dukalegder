const CACHE = 'dukaledger-shell-v1'
const SHELL = ['/', '/index.html', '/manifest.webmanifest', '/dukaledger-mark.svg', '/dukaledger-logo.svg', '/icon-192.png', '/icon-512.png']
self.addEventListener('install', event => event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting())))
self.addEventListener('activate', event => event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('dukaledger-shell-') && key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim())))
self.addEventListener('fetch', event => {
  const request = event.request
  const url = new URL(request.url)
  if (request.method !== 'GET' || url.origin !== self.location.origin) return
  if (url.pathname.startsWith('/rest/') || url.pathname.startsWith('/auth/') || url.pathname.startsWith('/storage/') || url.pathname.startsWith('/functions/')) return
  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).then(response => response).catch(() => caches.match('/index.html')))
    return
  }
  if (url.pathname.startsWith('/assets/')) {
    event.respondWith(caches.match(request).then(cached => cached || fetch(request).then(response => {
      if (response.ok) caches.open(CACHE).then(cache => cache.put(request, response.clone()))
      return response
    })))
    return
  }
  event.respondWith(caches.match(request).then(cached => cached || fetch(request)))
})
