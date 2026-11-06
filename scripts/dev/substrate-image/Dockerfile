# check=skip=InvalidDefaultArgInFrom
# (BASE_IMAGE hat bewusst keinen Default: der aufgeloeste Digest kommt immer aus bootstrap_test_n8n.ps1, eine Quelle.)
#
# Basis-Image des n8n-Test-Substrats: jrei/systemd-debian:12 + Basis-Pakete + PostgreSQL + Node + n8n in den
# gepinnten Versionen. Gebaut und getaggt NUR von scripts/dev/bootstrap_test_n8n.ps1 (Build-Kontext = ein
# Temp-Verzeichnis mit dieser Datei, build_base.sh und lib/ = Kopie aus provisioning/lib). Tag = Pins + Hash
# ueber die Build-Eingaben (Get-SubstrateBaseSpec) -> jede inhaltliche Aenderung baut neu; der jrei-Digest haengt als
# Label lifeagents.base-digest am Image. Prod/Release und `-Cold` nutzen dieses Image NIE.
#
# Bekannt und fuer Wegwerf-Dev vertretbar: Snakeoil-Zertifikat und PostgreSQL-Systemidentifier sind in allen
# Substraten aus demselben Image gleich.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG PG_VERSION
ARG N8N_VERSION
ARG NODE_MAJOR

LABEL lifeagents.substrate-base="1"

COPY build_base.sh /tmp/substrate-build/build_base.sh
COPY lib/ /tmp/substrate-build/lib/

# policy-rc.d exit 101: Paket-Skripte duerfen im Build keine Dienste starten (kein systemd); der postinst legt den
# PostgreSQL-Cluster trotzdem an. Das jrei-Image bringt sie (wie das offizielle debian-Image) schon mit; fehlt sie
# einmal, wird sie nur fuer den Build angelegt — der kalte Pfad soll dasselbe Image-Verhalten sehen.
# LANG="C" in /etc/default/locale: der Cluster entsteht unter derselben Schaerfe wie im Substrat/Proxmox (die
# UTF-8-Erzwingung kommt aus dem createcluster.d-Drop-in von install_pg_packages, nicht aus der System-Locale).
RUN set -eu; \
    own_policy=0; \
    if [ ! -e /usr/sbin/policy-rc.d ]; then printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d; own_policy=1; fi; \
    printf 'LANG="C"\n' > /etc/default/locale; \
    PG_VERSION="$PG_VERSION" N8N_VERSION="$N8N_VERSION" NODE_MAJOR="$NODE_MAJOR" bash /tmp/substrate-build/build_base.sh; \
    if [ "$own_policy" = 1 ]; then rm -f /usr/sbin/policy-rc.d; fi; \
    rm -rf /tmp/substrate-build /tmp/* /var/lib/apt/lists/* /root/.npm /root/.n8n
