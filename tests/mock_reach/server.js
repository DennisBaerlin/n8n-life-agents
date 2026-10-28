// mock_reach/server.js — lokaler Mock fuer scripts/dev/reachability_test.ps1 (tests/mock_reach/cases.sh).
// Spielt die Gegenstellen der Geraete-Erreichbarkeit (provisioning/lib/common.sh reach_probe_ip) auf Loopback-Adressen
// desselben Ports nach — je Adresse eine eigene Antwort:
//   127.0.0.1  = "n8n" (Referenz und "Proxy richtig")      127.0.0.2 = FRITZ!Box-Oberflaeche
//   127.0.0.3  = fremder Dienst (anderer Body)              127.0.0.4 = nichts (Verbindung abgelehnt)
//   ::1        = "n8n" (nur wenn der Container IPv6-Loopback hat)
// Mit MOCK_REACH_TLS_CERT/_KEY zusaetzlich ein HTTPS-Listener (selbstsigniert, Name reach.test) auf 127.0.0.1:<port+1> mit
// dem n8n-Body (auch fuer POST, z. B. /webhook-waiting-telegram der Bestaetigungs-Probe).
// Env: MOCK_REACH_PORT. Dependency-frei.
'use strict';
const http = require('http');
const https = require('https');
const fs = require('fs');

const port = Number(process.env.MOCK_REACH_PORT || 8091);
const bodies = {
  n8n: (path) => JSON.stringify({ code: 404, message: `The requested webhook "GET ${path}" is not registered.` }),
  fritz: () => '<!DOCTYPE html><html><head><title>FRITZ!Box</title></head><body>Die angegebene URL ist nicht verfügbar.</body></html>',
  other: () => '<html><body>Home Assistant</body></html>',
};

function handler(kind) {
  return (req, res) => {
    const path = (req.url || '/').replace(/^\/webhook\//, '');
    if (req.url === '/__pid') { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ pid: process.pid })); return; }
    res.writeHead(kind === 'n8n' ? 404 : 200, { 'content-type': kind === 'n8n' ? 'application/json' : 'text/html' });
    res.end(bodies[kind](path));
  };
}

const listeners = [['127.0.0.1', 'n8n'], ['127.0.0.2', 'fritz'], ['127.0.0.3', 'other']];
if (process.env.MOCK_REACH_IPV6 === '1') listeners.push(['::1', 'n8n']);
for (const [addr, kind] of listeners) {
  http.createServer(handler(kind)).listen(port, addr);
}
if (process.env.MOCK_REACH_TLS_CERT && process.env.MOCK_REACH_TLS_KEY) {
  https.createServer({ cert: fs.readFileSync(process.env.MOCK_REACH_TLS_CERT), key: fs.readFileSync(process.env.MOCK_REACH_TLS_KEY) },
    handler('n8n')).listen(port + 1, '127.0.0.1');
}
