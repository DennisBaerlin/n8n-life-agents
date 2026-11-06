# Test-Bild der Wizard-Tests (scripts/dev/wizard_test.ps1, Vorschau-Bilder): Node 24 wie im master, dazu bash, jq, curl und
# GNU date, die bridge.sh und die CLI-Pruefregeln brauchen. Kein n8n, keine Datenbank -- belegt keinen Testplatz.
FROM node:24-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
