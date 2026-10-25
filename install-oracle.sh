#!/bin/bash
# Écho Store — installation automatique sur une machine Oracle Cloud « Always Free » (Ubuntu).
# À coller dans « Script cloud-init » à la création de la machine, OU à lancer en SSH :  sudo bash install-oracle.sh
set -e
export DEBIAN_FRONTEND=noninteractive
SUPABASE_URL="https://haguqqwnfzpyveexzhej.supabase.co"
SUPABASE_KEY="sb_publishable_M0DNl76L_b9XSNzZeSZ7Rg_wlxmNYmE"

# 1) logiciels : Node.js 20 + Caddy (HTTPS automatique)
apt-get update -y
apt-get install -y curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https iptables-persistent cloud-guest-utils || apt-get install -y curl ca-certificates gnupg
if ! command -v node >/dev/null || [ "$(node -v | cut -c2- | cut -d. -f1)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y && apt-get install -y caddy
fi

# 2) le serveur Écho
mkdir -p /opt/echo-store /var/lib/echo-store
cat > /opt/echo-store/server.mjs <<'ECHO_SERVER_END'
// Écho Store — petit serveur de stockage pour ta musique (à installer sur Oracle Cloud « Always Free »).
// Aucune dépendance : Node 20+.
//   PUT    /o/<chemin>          envoi d'un fichier       (en-tête Authorization: Bearer <jeton Supabase>)
//   DELETE /o/<chemin>          suppression              (idem)
//   POST   /sign {paths:[...]}  liens signés valables 12 h (idem)
//   GET    /o/<chemin>?e=..&s=.. lecture (lien signé) — gère les « Range » pour l'audio
//   GET    /health              état + place disponible
import http from "node:http";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const PORT = +(process.env.PORT || 8080);
const DATA = path.resolve(process.env.DATA || "/var/lib/echo-store");
const SUPABASE_URL = (process.env.SUPABASE_URL || "").replace(/\/+$/, "");
const SUPABASE_KEY = process.env.SUPABASE_KEY || "";
const SECRET = process.env.SECRET || "";
const MAX = 2 * 1024 ** 3; // 2 Go par fichier
if (!SUPABASE_URL || !SUPABASE_KEY || SECRET.length < 32) { console.error("Config manquante (SUPABASE_URL, SUPABASE_KEY, SECRET)"); process.exit(1); }
fs.mkdirSync(DATA, { recursive: true });

const TYPES = { mp3: "audio/mpeg", flac: "audio/flac", m4a: "audio/mp4", aac: "audio/aac", wav: "audio/wav", ogg: "audio/ogg", opus: "audio/ogg", webm: "audio/webm", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp" };
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, HEAD, PUT, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Authorization, Content-Type, Range, x-upsert",
  "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges, ETag",
  "Access-Control-Max-Age": "86400",
};
const send = (res, code, body, headers = {}) => { res.writeHead(code, { ...cors, "Content-Type": "application/json", ...headers }); res.end(typeof body === "string" ? body : JSON.stringify(body)); };

// chemin sûr : <uid>/<...> sans « .. »
function safe(rel) {
  rel = decodeURIComponent(rel || "").replace(/^\/+/, "");
  if (!rel || rel.includes("\0") || rel.split("/").some(p => p === ".." || p === "." || p === "")) return null;
  const full = path.join(DATA, rel);
  return full.startsWith(DATA + path.sep) ? { rel, full } : null;
}
// vérification du jeton auprès de Supabase (mis en cache 5 min)
const cache = new Map();
async function userOf(req) {
  const tok = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!tok) return null;
  const c = cache.get(tok); if (c && c.exp > Date.now()) return c.uid;
  try {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SUPABASE_KEY, Authorization: `Bearer ${tok}` } });
    if (!r.ok) return null;
    const u = await r.json(); if (!u?.id) return null;
    cache.set(tok, { uid: u.id, exp: Date.now() + 5 * 60e3 });
    if (cache.size > 500) cache.delete(cache.keys().next().value);
    return u.id;
  } catch { return null; }
}
const sig = (rel, e) => crypto.createHmac("sha256", SECRET).update(`${rel}\n${e}`).digest("base64url");
const okSig = (rel, e, s) => { if (!e || !s || +e < Date.now() / 1000) return false; const a = Buffer.from(sig(rel, e)), b = Buffer.from(String(s)); return a.length === b.length && crypto.timingSafeEqual(a, b); };
const readBody = (req, lim = 1e6) => new Promise((ok, ko) => { let d = ""; req.on("data", c => { d += c; if (d.length > lim) { ko(new Error("trop gros")); req.destroy(); } }); req.on("end", () => ok(d)); req.on("error", ko); });

async function serveFile(req, res, f, dl) {
  let st; try { st = await fsp.stat(f.full); } catch { return send(res, 404, { error: "introuvable" }); }
  if (!st.isFile()) return send(res, 404, { error: "introuvable" });
  const type = TYPES[path.extname(f.rel).slice(1).toLowerCase()] || "application/octet-stream";
  const base = { ...cors, "Content-Type": type, "Accept-Ranges": "bytes", "Cache-Control": "private, max-age=31536000, immutable", ETag: `"${st.size}-${+st.mtime}"` };
  if (dl) base["Content-Disposition"] = `attachment; filename*=UTF-8''${encodeURIComponent(dl)}`;
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || "");
  if (m) {
    let a = m[1] === "" ? st.size - +m[2] : +m[1], b = m[1] !== "" && m[2] !== "" ? +m[2] : st.size - 1;
    if (isNaN(a) || a < 0 || a >= st.size || b < a) { res.writeHead(416, { ...base, "Content-Range": `bytes */${st.size}` }); return res.end(); }
    b = Math.min(b, st.size - 1);
    res.writeHead(206, { ...base, "Content-Range": `bytes ${a}-${b}/${st.size}`, "Content-Length": b - a + 1 });
    if (req.method === "HEAD") return res.end();
    return fs.createReadStream(f.full, { start: a, end: b }).pipe(res);
  }
  res.writeHead(200, { ...base, "Content-Length": st.size });
  if (req.method === "HEAD") return res.end();
  fs.createReadStream(f.full).pipe(res);
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    if (req.method === "OPTIONS") { res.writeHead(204, cors); return res.end(); }
    if (url.pathname === "/health") {
      let free = null; try { const s = await fsp.statfs(DATA); free = s.bavail * s.bsize; } catch {}
      return send(res, 200, { ok: true, app: "echo-store", free });
    }
    if (url.pathname === "/sign" && req.method === "POST") {
      const uid = await userOf(req); if (!uid) return send(res, 401, { error: "non autorisé" });
      const { paths = [], expiresIn = 43200 } = JSON.parse(await readBody(req) || "{}");
      const e = Math.floor(Date.now() / 1000) + Math.min(+expiresIn || 43200, 7 * 86400);
      const out = paths.slice(0, 5000).map(p => { const f = safe(p); return f && f.rel.startsWith(uid + "/") ? { path: p, signedUrl: `/o/${f.rel.split("/").map(encodeURIComponent).join("/")}?e=${e}&s=${sig(f.rel, e)}` } : { path: p, error: "interdit" }; });
      return send(res, 200, out);
    }
    // enregistreur radio : l'app lui donne sa clé (et peut le mettre en pause)
    if (url.pathname === "/rec" && (req.method === "POST" || req.method === "GET")) {
      const uid = await userOf(req); if (!uid) return send(res, 401, { error: "non autorisé" });
      const file = path.join(DATA, ".recorder.json"); let cur = {}; try { cur = JSON.parse(await fsp.readFile(file, "utf8")); } catch {}
      if (req.method === "GET") return send(res, 200, { linked: !!cur.key && cur.user === uid, on: cur.on !== false, installed: fs.existsSync("/opt/echo-store/recorder.mjs") });
      const b = JSON.parse(await readBody(req) || "{}");
      const next = { ...cur, user: uid };
      if (b.key) next.key = String(b.key);
      if (typeof b.on === "boolean") next.on = b.on;
      if (Array.isArray(b.podcasts)) next.podcasts = b.podcasts.map(String).slice(0, 30);
      await fsp.writeFile(file, JSON.stringify(next)); return send(res, 200, { ok: true, on: next.on !== false });
    }
    if (url.pathname.startsWith("/o/")) {
      const f = safe(url.pathname.slice(3)); if (!f) return send(res, 400, { error: "chemin invalide" });
      if (req.method === "GET" || req.method === "HEAD") {
        if (!okSig(f.rel, url.searchParams.get("e"), url.searchParams.get("s"))) return send(res, 403, { error: "lien expiré" });
        return serveFile(req, res, f, url.searchParams.get("dl"));
      }
      const uid = await userOf(req); if (!uid || !f.rel.startsWith(uid + "/")) return send(res, 401, { error: "non autorisé" });
      if (req.method === "DELETE") { await fsp.rm(f.full, { force: true }); return send(res, 200, { ok: true }); }
      if (req.method === "PUT" || req.method === "POST") {
        const len = +(req.headers["content-length"] || 0); if (len > MAX) return send(res, 413, { error: "fichier trop gros (2 Go max)" });
        await fsp.mkdir(path.dirname(f.full), { recursive: true });
        const tmp = `${f.full}.up-${crypto.randomBytes(4).toString("hex")}`;
        let size = 0, aborted = false;
        const ws = fs.createWriteStream(tmp);
        req.on("data", c => { size += c.length; if (size > MAX && !aborted) { aborted = true; req.destroy(); ws.destroy(); fsp.rm(tmp, { force: true }); } });
        req.pipe(ws);
        ws.on("finish", async () => { if (aborted) return; await fsp.rename(tmp, f.full); send(res, 200, { ok: true, path: f.rel, size }); });
        ws.on("error", async () => { await fsp.rm(tmp, { force: true }); if (!res.headersSent) send(res, 500, { error: "écriture impossible (disque plein ?)" }); });
        req.on("aborted", () => { aborted = true; ws.destroy(); fsp.rm(tmp, { force: true }); });
        return;
      }
    }
    send(res, 404, { error: "introuvable" });
  } catch (e) { if (!res.headersSent) send(res, 500, { error: String(e?.message || e) }); }
}).listen(PORT, "127.0.0.1", () => console.log(`Écho Store prêt sur 127.0.0.1:${PORT} — fichiers dans ${DATA}`));
ECHO_SERVER_END
[ -f /opt/echo-store/secret ] || head -c 48 /dev/urandom | base64 | tr -d '\n/+=' > /opt/echo-store/secret
id echostore >/dev/null 2>&1 || useradd --system --home /var/lib/echo-store --shell /usr/sbin/nologin echostore
chown -R echostore:echostore /var/lib/echo-store; chown echostore:echostore /opt/echo-store/secret; chmod 600 /opt/echo-store/secret
cat > /etc/systemd/system/echo-store.service <<ECHO_UNIT_END
[Unit]
Description=Echo Store
After=network-online.target
[Service]
User=echostore
Environment=PORT=8080 DATA=/var/lib/echo-store SUPABASE_URL=$SUPABASE_URL SUPABASE_KEY=$SUPABASE_KEY
ExecStart=/bin/sh -c 'SECRET=\$(cat /opt/echo-store/secret) exec /usr/bin/node /opt/echo-store/server.mjs'
Restart=always
[Install]
WantedBy=multi-user.target
ECHO_UNIT_END

# 2 bis) l'enregistreur radio (écoute les radios, ajoute les nouveaux morceaux et les podcasts à ta bibliothèque)
apt-get install -y ffmpeg
cat > /opt/echo-store/recorder.mjs <<'ECHO_REC_END'
// Écho — enregistreur radio (tourne 24 h/24 sur ton serveur Oracle, à côté d'Écho Store).
// Écoute les grandes radios, repère chaque morceau, l'enregistre s'il n'est pas déjà dans ta bibliothèque,
// le range avec les infos Apple Music (titre, artiste, album, pochette, genre) et l'ajoute à Écho.
// Télécharge aussi les derniers épisodes de quelques podcasts.  Node 20+ et ffmpeg.
// Usage privé uniquement (copie privée) : ne partage pas les fichiers enregistrés.
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import crypto from "node:crypto";

const DATA = path.resolve(process.env.DATA || "/var/lib/echo-store");
const SUPA = (process.env.SUPABASE_URL || "").replace(/\/+$/, "");
const PUB = process.env.SUPABASE_KEY || "";
const CONF = path.join(DATA, ".recorder.json");
const DONE = path.join(DATA, ".recorder-done.json");
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36";
const BUFFER_MS = 14 * 60e3; // on garde les 14 dernières minutes de chaque radio
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));

const STATIONS = ["NRJ", "Europe 2", "RTL2", "Fun Radio", "Skyrock", "Nostalgie", "Chérie FM", "RFM", "Virage Radio", "M Radio", "Radio FG",
  "Mouv'", "FIP", "Radio Nova", "OUI FM", "TSF Jazz", "Latina", "Générations", "Rire et Chansons", "Radio Scoop", "Contact FM", "Hit West", "Voltage", "Fréquence Plus", "Radio Meuh"];
const PODCASTS = ["Les Grosses Têtes", "Affaires sensibles", "Les Pieds sur terre"];
const RF_LIVEMETA = { "FIP": 7, "Mouv'": 6 };

// ---------- outils texte (mêmes règles que l'app) ----------
const norm = x => String(x || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/^the\s+/, "").replace(/[^a-z0-9]/g, "");
const primary = n => String(n || "").split(/\s+(?:feat\.?|ft\.?|featuring|x|with|avec)\s+|\s*[,;&\/]\s*/i)[0].trim() || n;
const cleanT = t => String(t || "").replace(/\s*[\(\[][^\)\]]*[\)\]]/g, "").replace(/\s+-\s+(radio edit|edit|version).*$/i, "").trim();
const keyOf = (a, t) => norm(primary(a)) + "|" + norm(cleanT(t));
function sim(a, b) { if (!a || !b) return 0; if (a === b) return 1; if (a.includes(b) || b.includes(a)) return Math.min(a.length, b.length) / Math.max(a.length, b.length) >= .6 ? .9 : .5;
  const g = s => { const m = new Map(); for (let i = 0; i < s.length - 1; i++) { const k = s.slice(i, i + 2); m.set(k, (m.get(k) || 0) + 1); } return m; };
  const A = g(a), B = g(b); let inter = 0; for (const [k, v] of A) inter += Math.min(v, B.get(k) || 0); return (2 * inter) / Math.max(1, a.length + b.length - 2); }
const ent = s => String(s || "").replace(/&amp;/g, "&").replace(/&#0?39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
const slug = s => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60) || "x";

// ---------- liaison avec ton compte Écho ----------
let conf = null, known = new Set(), knownIds = new Set(), done = new Set();
try { done = new Set(JSON.parse(fs.readFileSync(DONE, "utf8"))); } catch {}
const saveDone = () => fsp.writeFile(DONE, JSON.stringify([...done].slice(-20000))).catch(() => {});
async function api(action, extra = {}) {
  const r = await fetch(`${SUPA}/functions/v1/recingest`, { method: "POST", headers: { "Content-Type": "application/json", apikey: PUB, Authorization: `Bearer ${PUB}`, "x-rec-key": conf.key }, body: JSON.stringify({ action, ...extra }) });
  const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error(j.error || "HTTP " + r.status); return j;
}
async function refreshKnown() {
  try { const j = await api("known"); known = new Set(); knownIds = new Set();
    for (const [t, a, aa, id] of j.known) { known.add(keyOf(a, t)); if (aa) known.add(keyOf(aa, t)); if (id) knownIds.add(id); }
    log(`bibliothèque : ${j.known.length} morceaux connus`);
  } catch (e) { log("bibliothèque illisible :", e.message); }
}

// ---------- Apple Music (au plus 1 recherche toutes les 3,5 s) ----------
let amNext = 0;
async function itunes(q) {
  const w = Math.max(0, amNext - Date.now()); amNext = Math.max(Date.now(), amNext) + 3500; if (w) await sleep(w);
  try { const r = await fetch(`https://itunes.apple.com/${q}${q.includes("?") ? "&" : "?"}country=fr&lang=fr_fr`, { headers: { "User-Agent": UA } }); return r.ok ? await r.json() : null; } catch { return null; }
}
async function appleFind(artist, title, durGuess) {
  const r = await itunes(`search?term=${encodeURIComponent(`${primary(artist)} ${cleanT(title)}`)}&entity=song&limit=15`);
  const c = (r?.results || []).filter(x => x.kind === "song").map(x => ({ x, ts: sim(norm(cleanT(title)), norm(cleanT(x.trackName))), as: Math.max(sim(norm(primary(artist)), norm(primary(x.artistName))), sim(norm(primary(artist)), norm(primary(x.collectionArtistName || ""))) ) }))
    .filter(o => o.ts >= .9 && o.as >= .85);
  if (!c.length) return null;
  c.sort((a, b) => (b.ts + b.as) - (a.ts + a.as) || (durGuess ? Math.abs(a.x.trackTimeMillis / 1000 - durGuess) - Math.abs(b.x.trackTimeMillis / 1000 - durGuess) : 0));
  // version d'album plutôt que compilation
  const best = c.filter(o => !/compil|best of|hits|various/i.test((o.x.collectionName || "") + (o.x.collectionArtistName || "")))[0] || c[0];
  return best.x;
}

// ---------- empreinte sonore (même méthode que l'app) ----------
const SR = 11025, FN = 2048, FH = 512, NB = 24;
function fft(re, im) { const n = re.length; for (let i = 1, j = 0; i < n; i++) { let b = n >> 1; for (; j & b; b >>= 1) j ^= b; j ^= b; if (i < j) { let t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
  for (let len = 2; len <= n; len <<= 1) { const a = -2 * Math.PI / len, wr = Math.cos(a), wi = Math.sin(a); for (let i = 0; i < n; i += len) { let cr = 1, ci = 0; for (let j = 0; j < len / 2; j++) { const k = i + j + len / 2, ur = re[i + j], ui = im[i + j], vr = re[k] * cr - im[k] * ci, vi = re[k] * ci + im[k] * cr; re[i + j] = ur + vr; im[i + j] = ui + vi; re[k] = ur - vr; im[k] = ui - vi; const t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t; } } } }
const WIN = new Float32Array(FN).map((_, i) => 0.5 - 0.5 * Math.cos(2 * Math.PI * i / FN));
const mel = f => 2595 * Math.log10(1 + f / 700), MLO = mel(100), MHI = mel(4500), BAND = new Int8Array(FN / 2).fill(-1);
for (let k = 1; k < FN / 2; k++) { const m = mel(k * SR / FN); if (m >= MLO && m < MHI) BAND[k] = Math.floor((m - MLO) / (MHI - MLO) * NB); }
function feat(x) { const re = new Float64Array(FN), im = new Float64Array(FN), E = [];
  for (let p = 0; p + FN <= x.length; p += FH) { for (let i = 0; i < FN; i++) { re[i] = x[p + i] * WIN[i]; im[i] = 0; } fft(re, im); const e = new Float64Array(NB);
    for (let k = 1; k < FN / 2; k++) { const b = BAND[k]; if (b >= 0) e[b] += re[k] * re[k] + im[k] * im[k]; } for (let b = 0; b < NB; b++) e[b] = Math.log(1e-9 + e[b]); E.push(e); }
  const D = []; for (let t = 0; t + 1 < E.length; t++) { const d = new Float32Array(NB); for (let b = 0; b < NB; b++) d[b] = E[t + 1][b] - E[t][b]; D.push(d); } return D; }
function match(P, T) { if (!P.length || T.length < P.length) return { s: 0, at: 0 }; const n = P.length * NB; let pm = 0; for (const p of P) for (let b = 0; b < NB; b++) pm += p[b]; pm /= n;
  let ps = 0; for (const p of P) for (let b = 0; b < NB; b++) ps += (p[b] - pm) ** 2; ps = Math.sqrt(ps) || 1; let best = -1, at = 0;
  for (let l = 0; l <= T.length - P.length; l++) { let tm = 0; for (let i = 0; i < P.length; i++) { const t = T[l + i]; for (let b = 0; b < NB; b++) tm += t[b]; } tm /= n; let num = 0, ts = 0;
    for (let i = 0; i < P.length; i++) { const p = P[i], t = T[l + i]; for (let b = 0; b < NB; b++) { const dt = t[b] - tm; num += (p[b] - pm) * dt; ts += dt * dt; } } const s = num / (ps * (Math.sqrt(ts) || 1)); if (s > best) { best = s; at = l; } }
  return { s: best, at: at * FH / SR }; }
function run(cmd, args, input) { return new Promise((ok, ko) => { const p = spawn(cmd, args); const out = []; p.stdout.on("data", d => out.push(d)); p.stderr.on("data", () => {}); p.on("error", ko); p.on("close", c => c === 0 ? ok(Buffer.concat(out)) : ko(new Error(cmd + " code " + c))); if (input) { p.stdin.on("error", () => {}); p.stdin.end(input); } }); }
async function pcm(src, from = 0, len = 900) { // src : fichier ou adresse ; sortie 11 025 Hz mono
  const b = await run("ffmpeg", ["-v", "quiet", "-ss", String(from), "-t", String(len), "-i", src, "-ac", "1", "-ar", String(SR), "-f", "f32le", "pipe:1"]);
  const ab = b.buffer.slice(b.byteOffset, b.byteOffset + Math.floor(b.length / 4) * 4); return new Float32Array(ab);
}

// ---------- radios ----------
async function resolveStation(name) {
  for (const host of ["de1", "nl1", "at1"]) {
    try {
      const r = await fetch(`https://${host}.api.radio-browser.info/json/stations/search?name=${encodeURIComponent(name)}&countrycode=FR&hidebroken=true&order=votes&reverse=true&limit=25`, { headers: { "User-Agent": "Echo-Recorder/1.0" } });
      const l = (await r.json()).filter(s => /mp3|aac/i.test(s.codec || "") && !/\.m3u8|\.pls|\.m3u(\?|$)/i.test(s.url_resolved || "") && s.lastcheckok);
      const k = norm(name); const exact = l.filter(s => norm(s.name) === k), starts = l.filter(s => norm(s.name).startsWith(k));
      const pick = (exact.length ? exact : starts)[0]; if (pick) return { name, url: pick.url_resolved, codec: /aac/i.test(pick.codec) ? "aac" : "mp3" };
      return null;
    } catch {}
  }
  return null;
}
let rmSlugs = null;
async function rmSlug(name) {
  if (!rmSlugs) { rmSlugs = {};
    const pages = await Promise.all(Array.from({ length: 24 }, (_, i) => fetch(`https://radiomonitor.fr/radios?page=${i + 1}`, { headers: { "User-Agent": UA } }).then(r => r.ok ? r.text() : "").catch(() => "")));
    for (const h of pages) for (const m of h.matchAll(/radio\/([a-z0-9-]+)"\s*>\s*<h5[^>]*>([\s\S]*?)<\/h5>/g)) { const n = norm(ent(m[2])); if (n && !rmSlugs[n]) rmSlugs[n] = m[1]; } }
  const k = norm(name); if (rmSlugs[k]) return rmSlugs[k];
  const bare = s => s.replace(/^radio|radio$/g, "").replace(/fm$/, ""); const b = bare(k);
  const hit = Object.keys(rmSlugs).filter(x => bare(x) === b).sort((a, c) => a.length - c.length)[0]; return hit ? rmSlugs[hit] : null;
}
async function rmNow(slugName) {
  const r = await fetch(`https://radiomonitor.fr/radio/${slugName}`, { headers: { "User-Agent": UA, "Accept-Language": "fr-FR" } }).catch(() => null); if (!r?.ok) return null;
  const h = await r.text(); const s0 = h.indexOf("dernières musiques diffusées"); const a = h.indexOf("<tr", s0 >= 0 ? s0 : 0); if (a < 0) return null;
  const row = h.slice(a, h.indexOf("</tr>", a) + 5);
  const title = ent(/musique\/[^"]+"[^>]*>([\s\S]*?)<\/a>/.exec(row)?.[1] || ""); const artist = [...row.matchAll(/artiste\/[^"]+"[^>]*>([\s\S]*?)<\/a>/g)].map(m => ent(m[1])).filter(Boolean).join(", ");
  const tm = /(\d{2})\/(\d{2})\/(\d{4})\D+(\d{1,2}):(\d{2})/.exec(row.replace(/<[^>]*>/g, " "));
  if (!title || !tm) return null;
  // heure de Paris → horodatage
  const local = new Date(Date.UTC(+tm[3], +tm[2] - 1, +tm[1], +tm[4], +tm[5]));
  const offset = new Date(local.toLocaleString("en-US", { timeZone: "Europe/Paris" })).getTime() - new Date(local.toLocaleString("en-US", { timeZone: "UTC" })).getTime();
  return { artist, title, start: local.getTime() - offset };
}

class Station {
  constructor(name) { this.name = name; this.chunks = []; this.cur = null; this.ok = false; this.now = ""; this.src = ""; }
  async start() {
    for (;;) {
      try {
        const s = await resolveStation(this.name); if (!s) { this.now = "flux introuvable"; await sleep(30 * 60e3); continue; }
        this.url = s.url; this.codec = s.codec; this.slug = await rmSlug(this.name).catch(() => null);
        await this.listen();
      } catch (e) { this.ok = false; this.now = "coupé (" + (e.message || e) + ")"; }
      await sleep(15e3);
    }
  }
  async listen() {
    const ctl = new AbortController(); this.ctl = ctl;
    const r = await fetch(this.url, { headers: { "Icy-MetaData": "1", "User-Agent": "VLC/3.0.20 LibVLC/3.0.20" }, signal: ctl.signal });
    if (!r.ok || !r.body) throw new Error("HTTP " + r.status);
    const every = +(r.headers.get("icy-metaint") || 0); this.ok = true; this.icy = false;
    if (/aac/i.test(r.headers.get("content-type") || "")) this.codec = "aac";
    let left = every, metaLen = -1, meta = [];
    const poll = this.pollLoop();
    for await (const chunk of r.body) {
      const now = Date.now(); let i = 0; const audio = [];
      if (!every) audio.push(Buffer.from(chunk));
      else while (i < chunk.length) {
        if (metaLen < 0 && left > 0) { const n = Math.min(left, chunk.length - i); audio.push(Buffer.from(chunk.subarray(i, i + n))); i += n; left -= n; }
        else if (metaLen < 0) { metaLen = chunk[i++] * 16; meta = []; if (!metaLen) { metaLen = -1; left = every; } }
        else { const n = Math.min(metaLen - meta.reduce((s, b) => s + b.length, 0), chunk.length - i); meta.push(Buffer.from(chunk.subarray(i, i + n))); i += n;
          if (meta.reduce((s, b) => s + b.length, 0) >= metaLen) { this.onIcy(Buffer.concat(meta).toString("utf8"), now); metaLen = -1; left = every; } }
      }
      for (const b of audio) this.chunks.push({ t: now, b });
      while (this.chunks.length && now - this.chunks[0].t > BUFFER_MS) this.chunks.shift();
    }
    ctl.abort(); this.ok = false; await poll.catch(() => {});
  }
  onIcy(txt, t) {
    const m = /StreamTitle='(.*?)';/s.exec(txt); const v = (m?.[1] || "").trim();
    const p = /^(.+?)\s+-\s+(.+)$/.exec(v);
    if (!p || norm(v).includes(norm(this.name)) || /pub|jingle|flash|info trafic/i.test(v)) return;
    this.icy = true; this.event({ artist: p[1].trim(), title: p[2].trim(), start: t, precise: true });
  }
  async pollLoop() { // pas de titres dans le flux : Radio France (minutage exact) ou RadioMonitor
    while (this.ok) {
      try {
        if (!this.icy) {
          if (RF_LIVEMETA[this.name] != null) {
            const j = await (await fetch(`https://api.radiofrance.fr/livemeta/pull/${RF_LIVEMETA[this.name]}`)).json();
            const lv = j.levels?.[0]; const s = lv && j.steps?.[lv.items?.[lv.position]];
            if (s?.title && (s.authors || s.performers) && s.start) this.event({ artist: s.authors || s.performers, title: s.title, start: s.start * 1000, precise: true, end: s.end ? s.end * 1000 : null });
          } else if (this.slug) { const n = await rmNow(this.slug); if (n) this.event({ ...n, precise: false, seen: Date.now() }); }
        }
      } catch {}
      await sleep(25e3);
    }
  }
  event(e) {
    const k = keyOf(e.artist, e.title);
    if (this.cur && this.cur.k === k) return;
    this.now = `${e.artist} — ${e.title}`;
    const prev = this.cur; this.cur = { ...e, k };
    if (prev) { prev.end = prev.end || e.start; queue.push({ st: this, song: prev }); pump(); }
  }
  slice(t1, t2) { const parts = this.chunks.filter(c => c.t >= t1 && c.t <= t2).map(c => c.b); return parts.length ? Buffer.concat(parts) : null; }
}

// ---------- traitement des morceaux terminés ----------
const queue = []; let busy = false; const stats = { today: 0, day: new Date().toDateString(), last: [], pods: 0 };
async function pump() {
  if (busy) return; busy = true;
  while (queue.length) { const j = queue.shift(); try { await processSong(j.st, j.song); } catch (e) { log(j.st.name, "erreur :", e.message); } }
  busy = false;
}
async function processSong(st, s) {
  if (conf.on === false || known.has(s.k) || done.has(s.k)) return;
  const span = (s.end - s.start) / 1000; if (s.precise && (span < 75 || span > 600)) return;
  const x = await appleFind(s.artist, s.title, s.precise ? span : null);
  done.add(s.k); saveDone();
  if (!x) return;                                         // pas une chanson connue d'Apple (pub, émission…)
  if (knownIds.has(String(x.trackId)) || known.has(keyOf(x.artistName, x.trackName))) return;
  const D = x.trackTimeMillis / 1000; if (!D || D > 600) return;
  // fenêtre à garder dans la mémoire tampon
  let w1, w2;
  if (s.precise) { w1 = s.start - 1500; w2 = Math.min(s.end, s.start + D * 1000) + 1500; }
  else { const s0 = Math.min(Math.max(s.start + 30e3, s.seen - 150e3), s.seen); w1 = s0 - 45e3; w2 = s0 + D * 1000 + 60e3; }
  const raw = st.slice(w1, w2); if (!raw || raw.length < 200e3) return;
  const tmpDir = path.join(DATA, ".rec"); await fsp.mkdir(tmpDir, { recursive: true });
  const tmp = path.join(tmpDir, crypto.randomBytes(6).toString("hex") + (st.codec === "aac" ? ".aac" : ".mp3"));
  await fsp.writeFile(tmp, raw);
  try {
    let from = 0, len = (w2 - w1) / 1000;
    if (x.previewUrl) { // on vérifie que c'est bien ce morceau, et on cale le début grâce à l'extrait d'Apple
      const pvFile = tmp + ".pv.m4a"; const pr = await fetch(x.previewUrl); if (!pr.ok) throw new Error("extrait HTTP " + pr.status);
      await fsp.writeFile(pvFile, Buffer.from(await pr.arrayBuffer()));
      let pv; try { pv = await pcm(pvFile, 5, 20); } finally { fsp.rm(pvFile, { force: true }).catch(() => {}); }
      const rec = await pcm(tmp);
      const m = match(feat(pv), feat(rec));
      if (process.env.REC_DEBUG) log("debug", { pv: pv.length / SR, rec: rec.length / SR, raw: raw.length, s: m.s, at: m.at });
      if (m.s < .35) { log(st.name, "écarté (ne correspond pas) :", s.artist, "-", s.title, Math.round(m.s * 100) + "%"); return; }
      if (!s.precise) { const est = (Math.min(Math.max(s.start + 30e3, s.seen - 150e3), s.seen) - w1) / 1000;
        const S = Math.min(Math.max(est, m.at + 25 - D), m.at - 5); from = Math.max(0, S - 1.5); len = D + 3; }
    }
    const uid = conf.user, ext = st.codec === "aac" ? "m4a" : "mp3";
    const rel = `${uid}/radio/${slug(st.name)}/${Date.now()}-${slug(x.artistName + "-" + x.trackName)}.${ext}`;
    const out = path.join(DATA, rel); await fsp.mkdir(path.dirname(out), { recursive: true });
    const args = ["-v", "quiet", "-y", "-ss", String(from), "-t", String(len), "-i", tmp, "-map", "0:a", "-c", "copy", "-map_metadata", "-1",
      "-metadata", `title=${x.trackName}`, "-metadata", `artist=${x.artistName}`, "-metadata", `album=${x.collectionName || ""}`, "-metadata", `comment=Enregistré sur ${st.name}`];
    if (ext === "m4a") args.push("-bsf:a", "aac_adtstoasc");
    await run("ffmpeg", [...args, out]);
    const size = (await fsp.stat(out)).size;
    await api("add", { track: { title: x.trackName, artist: x.artistName, album: String(x.collectionName || "").replace(/ - (Single|EP)$/i, ""), album_artist: x.collectionArtistName || x.artistName,
      genre: x.primaryGenreName || null, year: x.releaseDate ? +x.releaseDate.slice(0, 4) : null, track_no: x.trackNumber || null, disc_no: x.discNumber || null,
      duration: Math.round(len), path: "ora:" + rel, size, cover_url: x.artworkUrl100 ? x.artworkUrl100.replace(/\/[^\/]+$/, "/600x600bb.jpg") : null, apple_id: x.trackId, tag_status: "auto" } });
    known.add(s.k); knownIds.add(String(x.trackId));
    if (stats.day !== new Date().toDateString()) { stats.day = new Date().toDateString(); stats.today = 0; }
    stats.today++; stats.last.unshift({ title: x.trackName, artist: x.artistName, station: st.name, at: new Date().toISOString() }); stats.last = stats.last.slice(0, 15);
    log(st.name, "✓ enregistré :", x.artistName, "-", x.trackName);
  } finally { fsp.rm(tmp, { force: true }).catch(() => {}); }
}

// ---------- podcasts : derniers épisodes (flux RSS trouvés via Apple Podcasts) ----------
async function podcasts() {
  if (conf.on === false) return;
  for (const name of conf.podcasts || PODCASTS) {
    try {
      const r = await itunes(`search?term=${encodeURIComponent(name)}&media=podcast&limit=3`); const p = (r?.results || []).find(x => x.feedUrl); if (!p) continue;
      const xml = await (await fetch(p.feedUrl, { headers: { "User-Agent": UA } })).text();
      const items = [...xml.matchAll(/<item[\s>][\s\S]*?<\/item>/g)].slice(0, 3).map(m => m[0]);
      for (const it of items) {
        const url = /<enclosure[^>]+url="([^"]+)"/.exec(it)?.[1]; const title = ent(/<title>([\s\S]*?)<\/title>/.exec(it)?.[1]?.replace(/<!\[CDATA\[|\]\]>/g, "") || "");
        const guid = "pod|" + (ent(/<guid[^>]*>([\s\S]*?)<\/guid>/.exec(it)?.[1] || "") || url);
        if (!url || !title || done.has(guid)) continue;
        const durTxt = ent(/<itunes:duration>([\s\S]*?)<\/itunes:duration>/.exec(it)?.[1] || ""); const dur = durTxt.includes(":") ? durTxt.split(":").reduce((s, v) => s * 60 + +v, 0) : +durTxt || null;
        const ext = /\.m4a(\?|$)/i.test(url) ? "m4a" : "mp3";
        const rel = `${conf.user}/podcasts/${slug(p.collectionName)}/${slug(title)}-${crypto.createHash("md5").update(guid).digest("hex").slice(0, 6)}.${ext}`;
        const out = path.join(DATA, rel); await fsp.mkdir(path.dirname(out), { recursive: true });
        const res = await fetch(url, { headers: { "User-Agent": UA } }); if (!res.ok) continue;
        await fsp.writeFile(out, Buffer.from(await res.arrayBuffer()));
        const size = (await fsp.stat(out)).size;
        await api("add", { track: { title, artist: p.artistName || p.collectionName, album: p.collectionName, album_artist: p.collectionName, genre: "Podcast",
          year: new Date().getFullYear(), duration: dur, path: "ora:" + rel, size, cover_url: (p.artworkUrl600 || p.artworkUrl100 || "").replace(/\/[^\/]+$/, "/600x600bb.jpg") || null, tag_status: "manual" } });
        done.add(guid); saveDone(); stats.pods++; log("podcast ✓", p.collectionName, "—", title);
      }
    } catch (e) { log("podcast", name, ":", e.message); }
  }
}

// ---------- démarrage ----------
const stations = [];
async function main() {
  log("Écho — enregistreur radio");
  for (;;) { try { conf = JSON.parse(fs.readFileSync(CONF, "utf8")); } catch { conf = null; } if (conf?.key && conf?.user) break; await sleep(30e3); }
  log("relié au compte", conf.user.slice(0, 8));
  await refreshKnown(); setInterval(refreshKnown, 30 * 60e3);
  setInterval(() => { try { const c = JSON.parse(fs.readFileSync(CONF, "utf8")); if (c.key !== conf.key) { conf = c; refreshKnown(); } conf.on = c.on; conf.podcasts = c.podcasts; } catch {} }, 60e3);
  for (const n of conf.stations || STATIONS) { const s = new Station(n); stations.push(s); s.start(); await sleep(1500); }
  const state = () => api("state", { state: { at: new Date().toISOString(), today: stats.today, pods: stats.pods, last: stats.last, stations: stations.map(s => ({ n: s.name, ok: s.ok, now: s.now })) } }).catch(() => {});
  setTimeout(state, 20e3); setInterval(state, 60e3);
  setTimeout(podcasts, 60e3); setInterval(podcasts, 3 * 3600e3);
}
main();
ECHO_REC_END
cat > /etc/systemd/system/echo-recorder.service <<ECHO_UNIT2_END
[Unit]
Description=Echo enregistreur radio
After=network-online.target echo-store.service
[Service]
User=echostore
Nice=5
Environment=DATA=/var/lib/echo-store SUPABASE_URL=$SUPABASE_URL SUPABASE_KEY=$SUPABASE_KEY
ExecStart=/usr/bin/node /opt/echo-store/recorder.mjs
Restart=always
RestartSec=20
[Install]
WantedBy=multi-user.target
ECHO_UNIT2_END

# 3) adresse publique en HTTPS : <ip-avec-tirets>.sslip.io (aucun nom de domaine à acheter)
IP=$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me)
HOST="$(echo "$IP" | tr . -).sslip.io"
cat > /etc/caddy/Caddyfile <<ECHO_CADDY_END
$HOST {
  request_body {
    max_size 2GB
  }
  reverse_proxy 127.0.0.1:8080 {
    flush_interval -1
  }
}
ECHO_CADDY_END

# 4) pare-feu de la machine (les images Oracle bloquent 80/443 par défaut)
for p in 80 443; do iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport $p -j ACCEPT; done
netfilter-persistent save 2>/dev/null || (mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4) || true

# 5) disque : utilise tout l'espace du disque de démarrage
ROOT=$(findmnt -n -o SOURCE /); DISK=/dev/$(lsblk -no PKNAME "$ROOT" 2>/dev/null); PART=$(echo "$ROOT" | grep -o '[0-9]*$')
[ -n "$PART" ] && growpart "$DISK" "$PART" 2>/dev/null && resize2fs "$ROOT" 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now echo-store echo-recorder
systemctl restart echo-store echo-recorder
systemctl restart caddy
echo "https://$HOST" > /opt/echo-store/adresse.txt
echo
echo "=============================================="
echo " Écho Store est prêt :  https://$HOST"
echo " Dans Écho → Réglages → Stockage Oracle, colle : $IP"
echo " Puis dans Écho → Radio → Enregistreur radio → Activer"
echo "=============================================="
