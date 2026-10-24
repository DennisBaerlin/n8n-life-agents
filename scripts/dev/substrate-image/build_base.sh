#!/usr/bin/env bash
# build_base.sh — fuellt das Basis-Image des Test-Substrats (laeuft NUR im `docker build`, Dockerfile daneben).
#
# WAS: die Software, die provision.sh bei jedem frischen Substrat sonst neu laedt (Basis-Pakete, PostgreSQL-Paket
# samt UTF-8-Cluster, Node, n8n, socat fuer die Test-Bruecke) — ueber DIESELBEN Funktionen wie der Installer
# (gesourct aus provisioning/lib, keine Kopie). provision.sh erkennt im Container danach alles als „schon da"
# (_node_ok, ensure_n8n_package-Versionsvergleich, install_postgres --only-upgrade-Zweig) und faehrt nur noch
# Schema/Owner/Credentials/Workflows. Kein systemd im Build: das Dockerfile verbietet Dienst-Starts per policy-rc.d.
#
# Bewusst NICHT gesourct: upgrade_guard.sh — ensure_n8n_package ruft upgrade_node_switched nur, wenn n8n schon
# installiert ist; im frischen Build ist dieser Zweig unerreichbar.
# Eingaben (Build-Args, eine Quelle = provision.sh, gelesen von bootstrap_test_n8n.ps1): PG_VERSION, N8N_VERSION,
# NODE_MAJOR.
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

: "${PG_VERSION:?}" "${N8N_VERSION:?}" "${NODE_MAJOR:?}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# shellcheck source=../../../provisioning/lib/common.sh
. "$LIB_DIR/common.sh"
# shellcheck source=../../../provisioning/lib/packages.sh
. "$LIB_DIR/packages.sh"
# shellcheck source=../../../provisioning/lib/install_pg.sh
. "$LIB_DIR/install_pg.sh"
# shellcheck source=../../../provisioning/lib/install_n8n.sh
. "$LIB_DIR/install_n8n.sh"

install_base_packages
install_pg_packages
ensure_node
ensure_n8n_package
apt_install socat   # Test-Bruecke (bootstrap_test_n8n.ps1 prueft `command -v socat` und installiert sonst nach)

# --- Plausibilitaet: genau die Pins, Cluster UTF-8 ---------------------------
[ "$(n8n --version)" = "$N8N_VERSION" ] || die "Basis-Image: n8n $(n8n --version) statt ${N8N_VERSION}."
_node_ok || die "Basis-Image: Node $(node -v) statt Hauptversion ${NODE_MAJOR}."
# Den Cluster kurz direkt starten (kein systemd im Build), Kodierung pruefen, sauber stoppen -> kein postmaster.pid
# und kein Recovery-Zustand im Image-Layer.
pg_ctlcluster "$PG_VERSION" main start
enc="$(runuser -u postgres -- psql -X -tAc "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='template1'")"
pg_ctlcluster "$PG_VERSION" main stop
[ "$enc" = "UTF8" ] || die "Basis-Image: PostgreSQL-Cluster ist ${enc}, nicht UTF8 (createcluster.d-Drop-in?)."
ok "Basis-Image: n8n ${N8N_VERSION}, Node $(node -v), PostgreSQL ${PG_VERSION} (Cluster UTF8), socat."
