# packages.sh — base OS packages the rest of the core depends on.
# Gesourct von provision.sh. Defines install_base_packages().

install_base_packages() {
  log "Basis-Pakete ..."
  apt_update_once
  # ca-certificates + curl + gnupg: APT key/repo fetches (PGDG/NodeSource). apt-transport-https:
  # older apt. lsb-release: some repo scripts probe it (we prefer /etc/os-release). jq: workflow/credential
  # JSON patching — installed here so the toolchain is complete on a bare image.
  # postgresql-client: psql for the schema steps. No htpasswd: owner-bootstrap creates the owner via n8n's
  # /rest/owner/setup with a plaintext password (n8n hashes it). No debian-keyring: the reverse proxy is
  # bring-your-own, so no Caddy apt repo is set up.
  apt_install \
    ca-certificates curl gnupg apt-transport-https lsb-release \
    jq openssl \
    postgresql-client
  ok "Basis-Pakete installiert."
}
