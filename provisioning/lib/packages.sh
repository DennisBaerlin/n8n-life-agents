# packages.sh — base OS packages the rest of the core depends on.
# Sourced by provision.sh. Defines install_base_packages().

install_base_packages() {
  log "Basis-Pakete ..."
  apt_update_once
  # ca-certificates + curl + gnupg: APT key/repo fetches (PGDG/NodeSource). apt-transport-https:
  # older apt. lsb-release: some repo scripts probe it (we prefer /etc/os-release). jq: Phase 2
  # workflow/credential JSON patching — pulled in now so the toolchain is complete on a bare image.
  # postgresql-client: psql for the schema steps. (No apache2-utils/htpasswd anymore: the Phase-5
  # owner-bootstrap creates the owner via n8n's /rest/owner/setup with a plaintext password — n8n
  # hashes it — so the bcrypt managed-env path and its htpasswd dependency are gone.)
  # (debian-keyring/debian-archive-keyring dropped in Install-UX-Phase 2: they were needed ONLY by
  # Caddy's apt repo, and Caddy is no longer installed — the reverse proxy is bring-your-own.)
  apt_install \
    ca-certificates curl gnupg apt-transport-https lsb-release \
    jq openssl \
    postgresql-client
  ok "Basis-Pakete installiert."
}
