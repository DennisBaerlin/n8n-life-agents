# master.Dockerfile — das eine eigene Image des Docker-Verbunds: darin laeuft provision.sh (LIFEAGENTS_RUNTIME=compose,
# compose.yml). Kein Datenbank-, n8n- oder Gateway-Server, nur die Werkzeuge des Installers + Docker-CLI mit Compose-Plugin,
# um die anderen Container des Verbunds zu steuern (lib/runtime.sh, Positivliste).
#
# Bau-Kontext = der Release-Baum, genau wie das Release-Asset (`git archive`, nur getrackte Dateien, LF laut .gitattributes):
#   git archive --format=tar HEAD provisioning packages .gitattributes | docker build -f provisioning/compose/master.Dockerfile -t <name> -
# Bau fuer amd64 + arm64, Veroeffentlichung und Digest in compose.yml: Paket 5 (Auslieferung der Images).
FROM node:24-bookworm-slim@sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c AS node
FROM docker:cli@sha256:4d742ab934c2149b628bf26369ac3ec51cb91e2e28fe6722a0e86a6d6efc4bd5 AS dockercli
FROM debian:12-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash jq curl gnupg ca-certificates openssl util-linux procps iproute2 \
 && rm -rf /var/lib/apt/lists/*
# Node (glibc-Build, Hauptversion 24 = NODE_MAJOR-Pin) fuer die n8n-Korrektur und die DNS-Probe; Docker-CLI ist statisch.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
# uid/gid 1000 = Nutzer "node" in den n8n-/Gateway-Images: Dateien root:n8n 0640 in den geteilten Volumes bleiben dort lesbar.
RUN groupadd -g 1000 n8n && useradd -u 1000 -g 1000 -M -d /nonexistent -s /usr/sbin/nologin n8n
COPY provisioning /opt/lifeagents/provisioning
COPY packages /opt/lifeagents/packages
LABEL io.lifeagents.install.image="master"
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LIFEAGENTS_RUNTIME=compose
WORKDIR /opt/lifeagents
# Ruhe-Prozess: der master wartet auf Auftraege (Wizard, Update) — der Dienst dafuer kommt mit Paket 2/4.
CMD ["sleep", "infinity"]
