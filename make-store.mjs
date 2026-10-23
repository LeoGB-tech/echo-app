// Fabrique le store perso (page + source AltStore/SideStore) et y ajoute la version web d'Écho.
import fs from "node:fs";
const { VERSION, REPO, OWNER } = process.env;
const [owner, repo] = REPO.split("/");
const base = `https://${owner.toLowerCase()}.github.io/${repo}`;
const rel = `https://github.com/${REPO}/releases/download/v${VERSION}`;
const size = f => (fs.existsSync(f) ? fs.statSync(f).size : 0);
const ipaSize = size("Echo.ipa"), apkSize = size("Echo.apk");
const today = new Date().toISOString().slice(0, 10);

fs.rmSync("_site", { recursive: true, force: true });
fs.mkdirSync("_site/app", { recursive: true });
for (const f of ["index.html","sw.js","manifest.webmanifest","icon.svg","icon-180.png","icon-192.png","icon-512.png"]) fs.copyFileSync(f, "_site/app/" + f);
fs.copyFileSync("icon.png", "_site/icon.png");

const source = {
  name: "Store de Leo",
  identifier: `io.github.${owner.toLowerCase()}.store`,
  subtitle: `Les apps de ${owner}`,
  description: "Mes apps, à installer avec SideStore ou AltStore.",
  iconURL: `${base}/icon.png`,
  website: base,
  tintColor: "#fa2d48",
  featuredApps: ["io.github.leogbtech.echo"],
  apps: [{
    name: "Écho",
    bundleIdentifier: "io.github.leogbtech.echo",
    developerName: owner,
    subtitle: "Ta musique, partout",
    localizedDescription: "Ton cloud musical perso : ta bibliothèque, tes playlists, la radio, les paroles synchronisées et tes récaps d'écoute.",
    iconURL: `${base}/icon.png`,
    tintColor: "#fa2d48",
    category: "entertainment",
    screenshots: [],
    versions: [{
      version: VERSION,
      buildVersion: VERSION.split(".").pop(),
      date: today,
      localizedDescription: `Écho ${VERSION}`,
      downloadURL: `${rel}/Echo.ipa`,
      size: ipaSize,
      minOSVersion: "14.0",
    }],
    appPermissions: { entitlements: [], privacy: {} },
  }],
  news: [],
};
fs.writeFileSync("_site/apps.json", JSON.stringify(source, null, 2));

const page = fs.readFileSync("store.html", "utf8")
  .replaceAll("{{VERSION}}", VERSION)
  .replaceAll("{{DATE}}", new Date().toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" }))
  .replaceAll("{{IPA_URL}}", `${rel}/Echo.ipa`)
  .replaceAll("{{APK_URL}}", `${rel}/Echo.apk`)
  .replaceAll("{{IPA_MB}}", (ipaSize / 1048576).toFixed(1))
  .replaceAll("{{APK_MB}}", (apkSize / 1048576).toFixed(1))
  .replaceAll("{{SOURCE_URL}}", `${base}/apps.json`)
  .replaceAll("{{SOURCE_ENC}}", encodeURIComponent(`${base}/apps.json`))
  .replaceAll("{{WEB_URL}}", `${base}/app/`);
fs.writeFileSync("_site/index.html", page);
console.log("Store prêt :", base, "· source :", `${base}/apps.json`, "· ipa", ipaSize, "o");
