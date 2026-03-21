#!/usr/bin/env bash
set -Eeuo pipefail

CERT_FILE="/etc/ssl/certs/ssl-cert-snakeoil.pem"
KEY_FILE="/etc/ssl/private/ssl-cert-snakeoil.key"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

SUDO=""
setup_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    SUDO=""
  else
    SUDO="sudo"
  fi
}

run_priv() {
  if [ -n "$SUDO" ]; then
    command -v sudo >/dev/null 2>&1 || {
      err "This operation requires root privileges, but sudo is not installed."
      exit 1
    }
    sudo "$@"
  else
    "$@"
  fi
}

file_nonempty() {
  run_priv test -s "$1"
}

generate_cert() {
  log "Installing certificate tooling..."
  export DEBIAN_FRONTEND=noninteractive
  run_priv apt-get update
  run_priv apt-get install -y --no-install-recommends openssl apache2 ssl-cert ca-certificates

  run_priv mkdir -p /etc/ssl/certs /etc/ssl/private

  log "Generating snakeoil certificate..."
  run_priv openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 3650 \
    -subj "/C=US/ST=State/L=City/O=Local/CN=$(hostname -f 2>/dev/null || hostname)"

  run_priv chmod 600 "$KEY_FILE"
  run_priv chmod 644 "$CERT_FILE"
  run_priv chown root:root "$KEY_FILE" "$CERT_FILE"
}

validate_cert() {
  file_nonempty "$CERT_FILE" || return 1
  file_nonempty "$KEY_FILE" || return 1
  run_priv openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || return 1
  run_priv openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 || return 1
}

test_apache() {
  log "Testing Apache configuration..."
  run_priv apachectl configtest
}

restart_apache_if_possible() {
  if command -v systemctl >/dev/null 2>&1 && run_priv systemctl status >/dev/null 2>&1; then
    run_priv systemctl restart apache2 || true
  elif command -v service >/dev/null 2>&1; then
    run_priv service apache2 restart || true
  else
    warn "No working service manager detected. Skipping Apache restart."
  fi
}

reconfigure_dpkg() {
  log "Retrying package configuration..."
  run_priv dpkg --configure -a
}

main() {
  setup_sudo

  if ! validate_cert; then
    warn "Certificate missing or invalid. Regenerating."
    generate_cert
  fi

  validate_cert || { err "Certificate generation failed."; exit 1; }
  test_apache
  restart_apache_if_possible
  reconfigure_dpkg
}

main "$@"

main "$@""

cd /tmp
wget https://repo.allstarlink.org/public/asl-apt-repos.deb13_all.deb
sudo dpkg -i asl-apt-repos.deb13_all.deb
sudo apt update
sudo apt install asl3-appliance-pc -y
