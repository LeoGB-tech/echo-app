// Écho — service worker : app utilisable sans réseau + notifications push.
// - le site et ses bibliothèques sont gardés en cache ;
// - pochettes, photos d'artistes et logos radio sont gardés dès qu'ils ont été vus (ou préchargés) ;
// - les morceaux téléchargés sont dans le cache "echo-offline" (géré par la page).
const SHELL = "echo-shell-v18", IMG = "echo-img-v1";
const FILES = ["./", "./index.html", "./manifest.webmanifest", "./icon.svg", "./icon-180.png", "./icon-192.png", "./icon-512.png"];
const CDN = /^(https:\/\/(cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|fonts\.googleapis\.com|fonts\.gstatic\.com))\//;
const IMG_HOSTS = /(^|\.)(dzcdn\.net|deezer\.com|wikimedia\.org|duckduckgo\.com|mzstatic\.com)$/;

self.addEventListener("install", e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(k => k.startsWith("echo-shell") && k !== SHELL).map(k => caches.delete(k))
  )).then(() => self.clients.claim()));
});

async function imageFirst(req, key) {
  const c = await caches.open(IMG);
  const hit = await c.match(key);
  if (hit) return hit;
  try {
    const r = await fetch(req);
    if (r.ok || r.type === "opaque") c.put(key, r.clone());
    return r;
  } catch (e) { return hit || Response.error(); }
}

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  // pochettes / photos stockées dans ton cloud : la clé ignore le jeton (qui change à chaque connexion)
  if (url.pathname.includes("/storage/v1/object/sign/music/") && /\/(covers|artists)\//.test(url.pathname)) {
    e.respondWith(imageFirst(req, url.origin + url.pathname)); return;
  }
  // pareil pour les pochettes sur ton serveur Oracle
  if(url.pathname.startsWith("/o/") && /\/(covers|artists)\//.test(url.pathname) && url.searchParams.has("s")){
    e.respondWith(imageFirst(req, url.origin + url.pathname)); return;
  }
  // photos d'artistes, pochettes de nouveautés, logos radio
  if (IMG_HOSTS.test(url.hostname) && !url.pathname.startsWith("/search") && !url.pathname.includes("/artist/") || (url.hostname === "www.google.com" && url.pathname.startsWith("/s2/favicons")) || (req.destination === "image" && url.origin !== self.location.origin)) {
    if (!(url.hostname === "api.deezer.com")) { e.respondWith(imageFirst(req, req.url)); return; }
  }
  const same = url.origin === self.location.origin;
  if (!same && !CDN.test(req.url)) return; // Supabase (données), paroles, radios : réseau direct
  if (req.mode === "navigate") {
    e.respondWith(fetch(req).then(r => { const c = r.clone(); caches.open(SHELL).then(x => x.put("./index.html", c)); return r; })
      .catch(() => caches.match("./index.html")));
    return;
  }
  e.respondWith(caches.match(req).then(hit => {
    const net = fetch(req).then(r => { if (r.ok || r.type === "opaque") { const c = r.clone(); caches.open(SHELL).then(x => x.put(req, c)); } return r; }).catch(() => hit);
    return hit || net;
  }));
});

// ---- notifications push (nouvelles sorties, récap) ----
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || "Écho", {
    body: d.body || "",
    icon: "icon-192.png",
    badge: "icon-192.png",
    image: d.image || undefined,
    tag: d.tag || undefined,
    data: { url: d.url || "./" },
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const target = new URL(e.notification.data?.url || "./", self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    for (const c of list) { if (c.url.startsWith(self.registration.scope)) { c.navigate(target).catch(() => {}); return c.focus(); } }
    return self.clients.openWindow(target);
  }));
});
