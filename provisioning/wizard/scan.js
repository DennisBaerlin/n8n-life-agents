// scan.js — Paperless im eigenen Heimnetz finden (Owner-Runde 2026-11-06: „Service-Gedanke“), nur wenn das Modul
// Dokumente gewählt ist und nur auf dessen Adress-Seite (server.js). Regeln:
//   - nur das /24-Netz des Rechners (Adresse von der App, LA_HOST_IP; größere Netze werden auf dieses /24 begrenzt);
//   - nur typische Paperless-Ports: 8000 (Standard von Paperless-ngx: PAPERLESS_PORT und die mitgelieferten
//     docker-compose-Dateien), 8010 (verbreiteter Ausweichport, wenn 8000 schon belegt ist, z. B. durch Portainer),
//     80 und 443 (Paperless hinter einem Reverse Proxy);
//   - kurze Wartezeit je Versuch, begrenzt parallel; nur GET, kein Anmelden, nichts schreiben, keine Daten mitsenden;
//   - Erkennung eindeutig an der Anmeldeseite /accounts/login/ (allauth, paperless/urls.py): sie erbt
//     paperless-ngx/base.html mit <meta name="author" content="Paperless-ngx project and contributors">. Die Kopfzeilen
//     X-Version/X-Api-Version sendet Paperless nur an Angemeldete (paperless/middleware.py ApiVersionMiddleware), taugen
//     also nicht für die Suche; die Version prüft danach der Live-Check mit Zugangstoken (bridge.sh paperless-check).
'use strict';
const http = require('http');
const https = require('https');

const PORTS = [8000, 8010, 80, 443];
const SIGNATURE = 'Paperless-ngx project and contributors';
const IPV4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;

function urlFor(ip, port) {
  if (port === 80) return `http://${ip}`;
  if (port === 443) return `https://${ip}`;
  return `http://${ip}:${port}`;
}

// probe(ip, port, timeoutMs) -> true, wenn dort Paperless antwortet. Nie wirft es; jeder Fehler = false.
function probe(ip, port, timeoutMs) {
  return new Promise((resolve) => {
    const mod = port === 443 ? https : http;
    let done = false;
    const end = (v) => { if (!done) { done = true; resolve(v); } };
    const req = mod.request({ host: ip, port, path: '/accounts/login/', method: 'GET', timeout: timeoutMs,
      rejectUnauthorized: false, headers: { 'User-Agent': 'lifeagents-setup', Accept: 'text/html' } }, (res) => {
      if (res.statusCode !== 200) { res.resume(); return end(false); }
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (d) => {
        body += d;
        if (body.includes(SIGNATURE)) { req.destroy(); end(true); } else if (body.length > 65536) { req.destroy(); end(false); }
      });
      res.on('end', () => end(body.includes(SIGNATURE)));
      res.on('error', () => end(false));
    });
    req.on('timeout', () => { req.destroy(); end(false); });
    req.on('error', () => end(false));
    req.end();
    // Harte Grenze gegen Gegenstellen, die tröpfchenweise antworten. Großzügig: beim ersten Lauf eines Prozesses kostet das
    // Anlaufen der TLS-Verbindungen (Port 443) spürbar Zeit, eine zu knappe Grenze verwarf so schon echte Treffer (Test).
    setTimeout(() => { req.destroy(); end(false); }, Math.max(2000, timeoutMs * 5)).unref();
  });
}

// scanPaperless({hostIp, ports, timeoutMs, concurrency}) -> Promise<[url, …]> (Rechner selbst zuerst, dann aufsteigend).
async function scanPaperless(o) {
  const hostIp = String(o.hostIp || '');
  if (!IPV4.test(hostIp) || /^(127\.|0\.|169\.254\.)/.test(hostIp)) return [];
  const base = hostIp.split('.').slice(0, 3).join('.');
  const own = Number(hostIp.split('.')[3]);
  const hosts = [own, ...Array.from({ length: 254 }, (_, i) => i + 1).filter((n) => n !== own)].map((n) => `${base}.${n}`);
  const ports = o.ports || PORTS;
  const jobs = [];
  for (const ip of hosts) for (const port of ports) jobs.push({ ip, port });
  const hits = new Set();
  // Der Rechner selbst zuerst und allein (häufigster Fall, ungestört vom Gedränge der übrigen Adressen).
  for (const j of jobs.slice(0, ports.length)) if (await probe(j.ip, j.port, o.timeoutMs || 400)) hits.add(urlFor(j.ip, j.port));
  let next = ports.length;
  const worker = async () => {
    while (next < jobs.length) {
      const j = jobs[next++];
      if (await probe(j.ip, j.port, o.timeoutMs || 400)) hits.add(urlFor(j.ip, j.port));
    }
  };
  await Promise.all(Array.from({ length: Math.min(o.concurrency || 48, jobs.length) }, worker));
  const order = new Map(jobs.map((j, i) => [urlFor(j.ip, j.port), i]));
  return [...hits].sort((a, b) => order.get(a) - order.get(b));
}

module.exports = { scanPaperless, probe, PORTS, SIGNATURE };
