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
