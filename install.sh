#!/usr/bin/env bash
set -Eeuo pipefail

CERT_FILE="/etc/ssl/certs/ssl-cert-snakeoil.pem"
KEY_FILE="/etc/ssl/private/ssl-cert-snakeoil.key"
APACHE_SSL_SITE="/etc/apache2/sites-enabled/default-ssl.conf"
DAYS="${DAYS:-3650}"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

err() {
  printf '[ERROR] %s\n' "$*" >&2
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Run this script as root."
    exit 1
  fi
}

install_packages() {
  log "Installing required packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends openssl apache2 ssl-cert ca-certificates
}

ensure_dirs() {
  mkdir -p /etc/ssl/certs /etc/ssl/private
  chmod 755 /etc/ssl/certs
  chmod 710 /etc/ssl/private || true
}

get_cn() {
  hostname -f 2>/dev/null || hostname
}

cert_is_valid() {
  [ -s "$CERT_FILE" ] &&
  [ -s "$KEY_FILE" ] &&
  openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 &&
  openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1
}

key_matches_cert() {
  local cert_mod key_mod
  cert_mod="$(openssl x509 -noout -modulus -in "$CERT_FILE" 2>/dev/null | openssl md5 2>/dev/null || true)"
  key_mod="$(openssl rsa  -noout -modulus -in "$KEY_FILE"  2>/dev/null | openssl md5 2>/dev/null || true)"
  [ -n "$cert_mod" ] && [ "$cert_mod" = "$key_mod" ]
}

generate_cert_openssl() {
  local cn
  cn="$(get_cn)"
  log "Generating self-signed certificate for CN=$cn ..."
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days "$DAYS" \
    -subj "/C=US/ST=State/L=City/O=Local/CN=$cn"
}

generate_cert_ssl_cert() {
  log "Generating default Debian snakeoil certificate..."
  make-ssl-cert generate-default-snakeoil --force-overwrite
}

fix_permissions() {
  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
  chown root:root "$KEY_FILE" "$CERT_FILE"

  if getent group ssl-cert >/dev/null 2>&1; then
    chgrp ssl-cert "$KEY_FILE" || true
    chmod 640 "$KEY_FILE" || true
  fi
}

show_apache_paths() {
  if [ -f "$APACHE_SSL_SITE" ]; then
    log "Current Apache SSL certificate directives:"
    grep -nE 'SSLCertificate(File|KeyFile|ChainFile)' "$APACHE_SSL_SITE" || true
  else
    warn "$APACHE_SSL_SITE not found. Apache SSL site may not be enabled yet."
  fi
}

verify_apache_expected_paths() {
  if [ -f "$APACHE_SSL_SITE" ]; then
    if grep -q 'SSLCertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem' "$APACHE_SSL_SITE"; then
      log "Apache SSL site points at expected certificate file."
    else
      warn "Apache SSL site does not point at $CERT_FILE"
    fi

    if grep -q 'SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key' "$APACHE_SSL_SITE"; then
      log "Apache SSL site points at expected key file."
    else
      warn "Apache SSL site does not point at $KEY_FILE"
    fi
  fi
}

test_apache() {
  log "Testing Apache configuration..."
  apachectl configtest
}

restart_apache() {
  log "Restarting Apache..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart apache2 || service apache2 restart
  else
    service apache2 restart
  fi
}

reconfigure_dpkg() {
  log "Retrying package configuration..."
  dpkg --configure -a
}

main() {
  require_root
  install_packages
  ensure_dirs
  show_apache_paths
  verify_apache_expected_paths

  if cert_is_valid && key_matches_cert; then
    log "Existing certificate and key are present and valid."
  else
    warn "Certificate or key missing, invalid, or mismatched."

    if command -v make-ssl-cert >/dev/null 2>&1; then
      generate_cert_ssl_cert
    else
      generate_cert_openssl
    fi
  fi

  fix_permissions

  if ! cert_is_valid; then
    err "Generated certificate or key is still invalid."
    exit 1
  fi

  if ! key_matches_cert; then
    err "Certificate and key do not match."
    exit 1
  fi

  test_apache
  restart_apache
  reconfigure_dpkg

  log "Done."
  log "Certificate: $CERT_FILE"
  log "Key:         $KEY_FILE"
}

main "$@"

cd /tmp
wget https://repo.allstarlink.org/public/asl-apt-repos.deb13_all.deb
sudo dpkg -i asl-apt-repos.deb13_all.deb
sudo apt update
sudo apt install asl3-appliance-pc -y
