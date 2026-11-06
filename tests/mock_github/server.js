// mock_github/server.js — lokaler Mock der GitHub-Release-API fuer scripts/dev/release_fetch_test.ps1.
//
// ZWECK: deterministisches, gratis Testen des echten Release-Downloads (provisioning/install.sh und
//   provisioning/lib/fetch_release.sh = `lifeagents update`) OHNE GitHub: immer anonym, nie ein Auth-Header,
//   kein Release / falsches Tag / Repo nicht oeffentlich, Abfragelimit, abgebrochener Download, Redirect.
//
// LAEUFT IM SUBSTRAT-CONTAINER; umgebogen wird der Download per PROVISION_GH_API=http://127.0.0.1:<port>
// (Test-Override, analog LIFEAGENTS_TELEGRAM_API). Zwei Ports: API (PORT) und "S3" (PORT+1) — Assets antworten
// mit 302 auf den zweiten Port wie GitHub auf eine signierte S3-URL. Der Mock zeichnet je Request auf, ob ein
// Authorization-Header kam (es darf nie einer kommen).
//
// Zustand je Fall per POST /__config {mode:"private"|"public", rate_limited, secondary_limit, no_latest, truncate_asset}
// (setzt auch das Log zurueck); secondary_limit = 403 mit retry-after (Zweitlimit); GET /__requests liefert die Aufzeichnung [{port, path, auth}] (auth = Header-Wert oder null).
// private = alles 404 (so zeigt sich ein privates Repo anonym); no_latest = /releases/latest 404 (kein stabiles
// Release); truncate_asset = "S3" bricht den Tarball nach den Headern ab (curl Exit 18 bei Status 200).
// Release-Daten: RELEASE_DIR/<tag>/ (Dateien = Assets), neuestes Tag = LATEST_TAG.
// Bewusst dependency-frei (nur Node-Core); Node ist durch n8n im Container garantiert.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.MOCK_GH_PORT || '8093', 10);   // 8093/8094: frei (8095-8099 = llm_gateway_test)
const S3_PORT = PORT + 1;
const SLUG = process.env.MOCK_GH_SLUG || 'owner/repo';
const RELEASE_DIR = process.env.MOCK_GH_RELEASE_DIR || '/tmp/mock_github/releases';
const LATEST_TAG = process.env.MOCK_GH_LATEST || 'v9.9.9';
const BODY_DIR = process.env.MOCK_GH_BODY_DIR || path.join(path.dirname(RELEASE_DIR), 'bodies');

let cfg = { mode: 'public', rate_limited: false, secondary_limit: false, no_latest: false, truncate_asset: false, latest: '' };
let requests = [];

function send(res, code, body, headers) {
  const h = Object.assign({ 'Content-Type': 'application/json' }, headers || {});
  res.writeHead(code, h);
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}

function assetsOf(tag) {
  const dir = path.join(RELEASE_DIR, tag);
  if (!fs.existsSync(dir)) return null;
  // url = API-Asset-Endpunkt (zaehlt bei GitHub gegen das Abfragelimit), browser_download_url = github.com-Download
  // (zaehlt nicht) — der Download soll die zweite nehmen; der Test prueft, dass die erste nie angefragt wird.
  return fs.readdirSync(dir).map((name, i) => ({
    id: i + 1, name,
    url: `http://127.0.0.1:${PORT}/repos/${SLUG}/releases/assets/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`,
    browser_download_url: `http://127.0.0.1:${PORT}/${SLUG}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`,
  }));
}

// Release-Objekt wie GitHub: Text (body) aus BODY_DIR/<tag>.md (Update-Karte im Chat liest den Einleitungsabsatz),
// html_url fuer den Link [Alle Aenderungen]; draft/prerelease aus BODY_DIR/<tag>.flags ("draft"|"prerelease").
function releaseObj(tag) {
  const assets = assetsOf(tag);
  if (!assets) return null;
  const read = (ext) => { const f = path.join(BODY_DIR, `${tag}.${ext}`); return fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : ''; };
  const flags = read('flags');
  return { tag_name: tag, prerelease: flags.includes('prerelease'), draft: flags.includes('draft'), body: read('md'),
           html_url: `https://example.org/${SLUG}/releases/tag/${encodeURIComponent(tag)}`, assets };
}

function release(res, tag) {
  const r = releaseObj(tag);
  if (!r) return send(res, 404, { message: 'Not Found' });
  send(res, 200, r);
}

// GET /releases: alle Releases, neueste zuerst (wie GitHub nach Erstellung; hier nach Versions-Ordnung).
function releases(res) {
  const tags = fs.existsSync(RELEASE_DIR) ? fs.readdirSync(RELEASE_DIR) : [];
  tags.sort((a, b) => b.localeCompare(a, 'en', { numeric: true }));
  send(res, 200, tags.map(releaseObj).filter(Boolean));
}

const api = http.createServer((req, res) => {
  const p = new URL(req.url, 'http://x').pathname;
  if (p === '/__config' && req.method === 'POST') {
    let b = '';
    req.on('data', (c) => { b += c; });
    req.on('end', () => { cfg = Object.assign(cfg, JSON.parse(b || '{}')); requests = []; send(res, 200, cfg); });
    return;
  }
  if (p === '/__requests') return send(res, 200, requests);
  if (p === '/__pid') return send(res, 200, { pid: process.pid });   // cases.sh: antwortet wirklich DIESER Prozess?
  requests.push({ port: PORT, path: p, auth: req.headers.authorization || null });
  if (cfg.rate_limited) return send(res, 403, { message: 'API rate limit exceeded' }, { 'x-ratelimit-remaining': '0' });
  if (cfg.secondary_limit) return send(res, 403, { message: 'secondary rate limit' }, { 'x-ratelimit-remaining': '50', 'retry-after': '60' });
  if (cfg.mode === 'private') return send(res, 404, { message: 'Not Found' });
  const mDl = p.match(new RegExp(`^/${SLUG}/releases/download/([^/]+)/([^/]+)$`));
  if (mDl) return send(res, 302, '', { Location: `http://127.0.0.1:${S3_PORT}/s3/${mDl[1]}/${mDl[2]}` });
  const base = `/repos/${SLUG}`;
  if (p === `${base}/releases/latest`) return cfg.no_latest ? send(res, 404, { message: 'Not Found' }) : release(res, cfg.latest || LATEST_TAG);
  if (p === `${base}/releases`) return releases(res);
  const mTag = p.match(new RegExp(`^${base}/releases/tags/([^/]+)$`));
  if (mTag) return release(res, decodeURIComponent(mTag[1]));
  const mAsset = p.match(new RegExp(`^${base}/releases/assets/([^/]+)/([^/]+)$`));
  if (mAsset) {
    if (req.headers.accept !== 'application/octet-stream') return send(res, 415, { message: 'Accept octet-stream' });
    return send(res, 302, '', { Location: `http://127.0.0.1:${S3_PORT}/s3/${mAsset[1]}/${mAsset[2]}` });
  }
  send(res, 404, { message: 'Not Found' });
});

// "S3": vorsignierte Ziel-URL — kein Auth noetig, ein mitgeschickter Header wird nur aufgezeichnet.
const s3 = http.createServer((req, res) => {
  const p = new URL(req.url, 'http://x').pathname;
  requests.push({ port: S3_PORT, path: p, auth: req.headers.authorization || null });
  const m = p.match(/^\/s3\/([^/]+)\/([^/]+)$/);
  const f = m && path.join(RELEASE_DIR, decodeURIComponent(m[1]), decodeURIComponent(m[2]));
  if (!f || !fs.existsSync(f)) return send(res, 404, { message: 'Not Found' });
  const body = fs.readFileSync(f);
  if (cfg.truncate_asset && f.endsWith('.tar.gz')) {
    // Abbruch nach den Headern: Content-Length verspricht mehr, als kommt -> curl meldet 200 + Exit 18.
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': body.length + 1000 });
    res.write(body.subarray(0, Math.floor(body.length / 2)));
    return setTimeout(() => res.destroy(), 100);   // erst Header + Teil-Body raus, dann Verbindung kappen
  }
  send(res, 200, body, { 'Content-Type': 'application/octet-stream' });
});

api.listen(PORT, '127.0.0.1');
s3.listen(S3_PORT, '127.0.0.1');
