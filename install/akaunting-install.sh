#!/usr/bin/env bash
set -Eeuo pipefail

# Copyright (c) 2026 Akaunting-LXC contributors
# License: GPL-3.0 | https://github.com/trinityr/Akaunting-LXC/raw/main/LICENSE
# Source: https://akaunting.com/ | https://github.com/akaunting/docker
#
# Runs INSIDE the LXC container. Installs Docker and PostgreSQL, creates the
# Akaunting database/role, builds a Postgres-enabled Akaunting image (the
# upstream akaunting/akaunting image only ships pdo_mysql), and runs it.

msg_info() { echo -e "  [*] $1"; }
msg_ok() { echo -e "  [+] $1"; }
msg_error() { echo -e "  [!] $1" >&2; }

export DEBIAN_FRONTEND=noninteractive

# `pct exec` inherits LANG from the Proxmox host (often en_US.UTF-8), but the
# minimal Debian template never generates that locale, so every apt/dpkg
# perl script warns and falls back to C. C.UTF-8 is a glibc built-in that
# needs no locale-gen, so pin to it explicitly instead of fighting the
# inherited env.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# `runuser -u postgres` tries to re-enter the caller's cwd (/root) as the
# postgres user, which it can't read - harmless but noisy. /tmp is
# world-readable, so run from there instead.
cd /tmp

BASE_IMAGE="docker.io/akaunting/akaunting:latest"
IMAGE_TAG="akaunting-pgsql:local"
CONTAINER_NAME="akaunting"
VOLUME_NAME="akaunting-data"
STATE_FILE="/root/akaunting.env"
CRED_FILE="/root/akaunting-credentials.txt"

gen_secret() {
  openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 24
}

get_ip() {
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -n1
}

# Best-effort default: the /24 network containing the container's own eth0
# address. Good enough for typical flat home/office LANs; override
# PG_ALLOWED_CIDR for anything else (a /16, a single host, etc).
detect_default_cidr() {
  local cidr ip a b c
  cidr=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | head -n1)
  if [[ -z "$cidr" ]]; then
    echo "127.0.0.1/32"
    return
  fi
  ip="${cidr%/*}"
  IFS=. read -r a b c _ <<<"$ip"
  echo "${a}.${b}.${c}.0/24"
}

install_docker() {
  msg_info "Updating package lists"
  apt-get update -qq
  msg_ok "Updated package lists"

  msg_info "Installing Docker"
  apt-get install -y -qq docker.io ca-certificates curl openssl >/dev/null
  systemctl enable -q --now docker
  msg_ok "Installed Docker"
}

install_postgres() {
  msg_info "Installing PostgreSQL"
  apt-get install -y -qq postgresql >/dev/null
  systemctl enable -q --now postgresql
  msg_ok "Installed PostgreSQL"
}

configure_postgres() {
  msg_info "Configuring PostgreSQL to accept connections from Docker and ${PG_ALLOWED_CIDR}"
  local pg_version pg_conf pg_hba
  pg_version=$(ls /etc/postgresql)
  pg_conf="/etc/postgresql/${pg_version}/main/postgresql.conf"
  pg_hba="/etc/postgresql/${pg_version}/main/pg_hba.conf"

  sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$pg_conf"

  if ! grep -q "akaunting-lxc" "$pg_hba"; then
    {
      echo ""
      echo "# akaunting-lxc: required for the Akaunting docker container to reach Postgres"
      echo "host    all             all             172.16.0.0/12           scram-sha-256"
      echo "# akaunting-lxc: allows external clients (psql, pgAdmin, ...) to manage the akaunting DB"
      echo "host    all             all             ${PG_ALLOWED_CIDR}      scram-sha-256"
    } >>"$pg_hba"
  fi

  systemctl restart postgresql
  msg_ok "PostgreSQL listening on all interfaces (LAN access: ${PG_ALLOWED_CIDR}, password required)"
}

create_database() {
  msg_info "Creating PostgreSQL role and database for Akaunting"
  local role_exists db_exists
  role_exists=$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${AKAUNTING_DB_USER}'")
  if [[ "$role_exists" == "1" ]]; then
    runuser -u postgres -- psql -c "ALTER ROLE \"${AKAUNTING_DB_USER}\" WITH LOGIN PASSWORD '${AKAUNTING_DB_PASSWORD}';" >/dev/null
  else
    runuser -u postgres -- psql -c "CREATE ROLE \"${AKAUNTING_DB_USER}\" WITH LOGIN PASSWORD '${AKAUNTING_DB_PASSWORD}';" >/dev/null
  fi

  db_exists=$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${AKAUNTING_DB_NAME}'")
  if [[ "$db_exists" != "1" ]]; then
    runuser -u postgres -- psql -c "CREATE DATABASE \"${AKAUNTING_DB_NAME}\" OWNER \"${AKAUNTING_DB_USER}\";" >/dev/null
  fi
  msg_ok "Database '${AKAUNTING_DB_NAME}' ready for user '${AKAUNTING_DB_USER}'"
}

# The upstream akaunting/akaunting image only compiles in pdo_mysql. libpq-dev
# and build-essential are already present in that image (just not the
# extension itself), so this layer needs no extra apt packages or network
# access beyond pulling the base image.
build_image() {
  msg_info "Pulling latest Akaunting image"
  docker pull -q "$BASE_IMAGE" >/dev/null
  msg_ok "Pulled ${BASE_IMAGE}"

  msg_info "Adding PostgreSQL support (pdo_pgsql) to the Akaunting image"
  local build_dir
  build_dir=$(mktemp -d)
  cat <<EOF >"${build_dir}/Dockerfile"
FROM ${BASE_IMAGE}
RUN docker-php-ext-install pdo_pgsql pgsql
EOF
  docker build -q -t "$IMAGE_TAG" "$build_dir" >/dev/null
  rm -rf "$build_dir"
  msg_ok "Built ${IMAGE_TAG}"
}

# run_container true  -> first run: let Akaunting's CLI installer create the
#                        company/admin/tables (only safe to do once).
# run_container false -> redeploy against an already-installed database.
run_container() {
  local first_run="$1"

  docker volume create "$VOLUME_NAME" >/dev/null
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  local setup_args=()
  if [[ "$first_run" == "true" ]]; then
    setup_args=(
      -e AKAUNTING_SETUP=true
      -e "COMPANY_NAME=${AKAUNTING_COMPANY_NAME}"
      -e "COMPANY_EMAIL=${AKAUNTING_COMPANY_EMAIL}"
      -e "ADMIN_EMAIL=${AKAUNTING_ADMIN_EMAIL}"
      -e "ADMIN_PASSWORD=${AKAUNTING_ADMIN_PASSWORD}"
    )
  fi

  msg_info "Starting the Akaunting container"
  docker run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --add-host=host.docker.internal:host-gateway \
    -p "${AKAUNTING_PORT}:80" \
    -v "${VOLUME_NAME}:/var/www/html" \
    -e DB_CONNECTION=pgsql \
    -e DB_HOST=host.docker.internal \
    -e DB_PORT=5432 \
    -e "DB_NAME=${AKAUNTING_DB_NAME}" \
    -e "DB_USERNAME=${AKAUNTING_DB_USER}" \
    -e "DB_PASSWORD=${AKAUNTING_DB_PASSWORD}" \
    -e DB_PREFIX=ak_ \
    -e "LOCALE=${AKAUNTING_LOCALE}" \
    -e "APP_URL=${AKAUNTING_APP_URL}" \
    "${setup_args[@]}" \
    "$IMAGE_TAG" >/dev/null
  msg_ok "Started the Akaunting container"
}

wait_for_akaunting() {
  msg_info "Waiting for Akaunting to come up (first run also runs the CLI installer)"
  local tries=0 code="000"
  while [[ $tries -lt 60 ]]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${AKAUNTING_PORT}/" || true)
    [[ "$code" != "000" ]] && break
    sleep 5
    tries=$((tries + 1))
  done
  if [[ "$code" == "000" ]]; then
    msg_error "Akaunting did not respond on port ${AKAUNTING_PORT} in time. Check: docker logs ${CONTAINER_NAME}"
    exit 1
  fi
  msg_ok "Akaunting is responding (HTTP ${code})"
}

install_caddy() {
  msg_info "Installing Caddy"
  curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/local/bin/caddy
  chmod +x /usr/local/bin/caddy
  msg_ok "Installed Caddy $(/usr/local/bin/caddy version 2>/dev/null | awk '{print $1}')"

  getent group caddy >/dev/null || groupadd --system caddy
  getent passwd caddy >/dev/null || useradd --system --gid caddy --home-dir /var/lib/caddy \
    --no-create-home --shell /usr/sbin/nologin --comment "Caddy web server" caddy
  mkdir -p /etc/caddy /var/lib/caddy
  chown -R caddy:caddy /var/lib/caddy

  msg_info "Writing Caddy config for ${AKAUNTING_DOMAIN}"
  {
    if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
      echo "{"
      echo "    email ${LETSENCRYPT_EMAIL}"
      echo "}"
      echo
    fi
    echo "${AKAUNTING_DOMAIN} {"
    echo "    reverse_proxy 127.0.0.1:${AKAUNTING_PORT}"
    echo "}"
  } >/etc/caddy/Caddyfile
  msg_ok "Wrote /etc/caddy/Caddyfile"

  cat <<'EOF' >/etc/systemd/system/caddy.service
[Unit]
Description=Caddy (Akaunting reverse proxy)
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# Requesting a certificate before DNS/port-forwarding is actually in place
# just burns Let's Encrypt's rate limit on failed attempts, so pause here
# (interactively - this is meant to be run while watching the terminal) and
# let the operator confirm routing before Caddy makes its first request.
confirm_https_ready() {
  echo
  echo "Caddy is configured for https://${AKAUNTING_DOMAIN} but hasn't requested a certificate yet."
  echo "Before continuing, make sure:"
  echo "  1. DNS for ${AKAUNTING_DOMAIN} resolves to wherever this container is reachable from the internet"
  echo "  2. Ports 80 and 443 reach this container (port-forwarded to $(get_ip), if needed)"
  echo
  echo "Let's Encrypt rate-limits failed attempts, so it's worth confirming before Caddy requests anything."
  if [[ -t 0 ]]; then
    read -r -p "Press Enter to continue and request the certificate... " _
  else
    msg_info "Non-interactive shell - skipping the confirmation pause"
  fi
}

wait_for_https() {
  msg_info "Waiting for Caddy to obtain the certificate and respond over HTTPS"
  # Connect straight to Caddy on localhost rather than the public domain:
  # many home routers don't support NAT hairpinning (reaching your own
  # public IP/domain from inside your own LAN), which would otherwise make
  # this look like a failure even when the certificate and external access
  # are both fine. --resolve still sends the right SNI/Host for Caddy to
  # pick the site and for the cert's hostname to validate correctly.
  local tries=0 code="000"
  while [[ $tries -lt 30 ]]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "${AKAUNTING_DOMAIN}:443:127.0.0.1" "https://${AKAUNTING_DOMAIN}/" || true)
    [[ "$code" != "000" ]] && break
    sleep 5
    tries=$((tries + 1))
  done
  if [[ "$code" == "000" ]]; then
    msg_error "Caddy did not respond over HTTPS in time. Check: journalctl -u caddy -n 50 --no-pager"
    msg_error "Akaunting itself is fine at http://$(get_ip):${AKAUNTING_PORT} - fix DNS/routing and 'systemctl restart caddy' once ready."
  else
    msg_ok "Caddy is responding over HTTPS (HTTP ${code})"
  fi
}

setup_motd() {
  cat <<'SCRIPT' >/usr/local/bin/akaunting-motd.sh
#!/bin/sh
IPV4=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -n1)
IPV6=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep ':' | head -n1)
OS_PRETTY=$( . /etc/os-release 2>/dev/null; echo "$PRETTY_NAME" )
PG_VERSION=$(runuser -u postgres -- psql -tAc 'SHOW server_version;' 2>/dev/null || echo "not running")
AKAUNTING_PORT=$(cat /root/.akaunting_port 2>/dev/null || echo "8080")

{
  echo ""
  echo "  ------------------------------------------"
  echo "   Akaunting (LXC, Docker + PostgreSQL)"
  echo "  ------------------------------------------"
  echo "   OS Version    : ${OS_PRETTY:-unknown}"
  echo "   PostgreSQL    : ${PG_VERSION}"
  echo "   IPv4 Address  : ${IPV4:-not assigned}"
  echo "   IPv6 Address  : ${IPV6:-not assigned}"
  echo "   Web UI        : http://${IPV4:-<ip>}:${AKAUNTING_PORT}"
  echo "   Postgres port : 5432"
  echo "   Credentials   : /root/akaunting-credentials.txt"
  echo "  ------------------------------------------"
  echo ""
} >/etc/motd
SCRIPT
  chmod +x /usr/local/bin/akaunting-motd.sh

  cat <<EOF >/etc/systemd/system/akaunting-motd.service
[Unit]
Description=Generate Akaunting MOTD
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/akaunting-motd.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q akaunting-motd.service
  echo "$AKAUNTING_PORT" >/root/.akaunting_port
  /usr/local/bin/akaunting-motd.sh
}

# Autologin root on the LXC console (tty1, what `pct console` attaches to).
# Still execs the real `login` program (via agetty --autologin), so PAM's
# session hooks - including the motd display - still run; it just skips
# the password prompt. Console access already requires Proxmox host access,
# so this trades a redundant password prompt for the MOTD being visible
# without needing any credentials for this container at all.
setup_console_autologin() {
  mkdir -p /etc/systemd/system/container-getty@1.service.d
  cat <<'EOF' >/etc/systemd/system/container-getty@1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear - $TERM
EOF
  systemctl daemon-reload
  systemctl restart container-getty@1.service 2>/dev/null || true
}

print_summary() {
  local ip
  ip=$(get_ip)

  local web_ui_line="Akaunting web UI : http://${ip}:${AKAUNTING_PORT} (direct)"
  if [[ "$ENABLE_HTTPS" == "1" ]]; then
    web_ui_line="${web_ui_line}, https://${AKAUNTING_DOMAIN} (via Caddy)"
  fi

  cat <<EOF >"$CRED_FILE"
${web_ui_line}
Akaunting APP_URL: ${AKAUNTING_APP_URL} (used for links/redirects/emails - update via a reinstall or by editing .env if you add a reverse proxy later)
Admin login      : ${AKAUNTING_ADMIN_EMAIL} / ${AKAUNTING_ADMIN_PASSWORD}

PostgreSQL host (from other machines) : ${ip}:5432
PostgreSQL host (from this container) : 127.0.0.1:5432
Database                              : ${AKAUNTING_DB_NAME}
User                                   : ${AKAUNTING_DB_USER}
Password                               : ${AKAUNTING_DB_PASSWORD}
Allowed client network (besides Docker): ${PG_ALLOWED_CIDR}
EOF
  chmod 600 "$CRED_FILE"

  echo
  echo "=================================================================="
  cat "$CRED_FILE"
  echo "=================================================================="
  echo "Saved to ${CRED_FILE} (root-only) inside the container."
}

if [[ "${1:-}" == "update" ]]; then
  if [[ ! -f "$STATE_FILE" ]]; then
    msg_error "No existing Akaunting installation found (${STATE_FILE} is missing)."
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  build_image
  run_container false
  wait_for_akaunting
  msg_ok "Updated Akaunting to the latest image"
  exit 0
fi

AKAUNTING_PORT="${AKAUNTING_PORT:-8080}"
AKAUNTING_DB_NAME="${AKAUNTING_DB_NAME:-akaunting}"
AKAUNTING_DB_USER="${AKAUNTING_DB_USER:-akaunting}"
AKAUNTING_DB_PASSWORD="${AKAUNTING_DB_PASSWORD:-}"
AKAUNTING_ADMIN_EMAIL="${AKAUNTING_ADMIN_EMAIL:-admin@akaunting.local}"
AKAUNTING_ADMIN_PASSWORD="${AKAUNTING_ADMIN_PASSWORD:-}"
AKAUNTING_COMPANY_NAME="${AKAUNTING_COMPANY_NAME:-My Company}"
AKAUNTING_COMPANY_EMAIL="${AKAUNTING_COMPANY_EMAIL:-$AKAUNTING_ADMIN_EMAIL}"
AKAUNTING_LOCALE="${AKAUNTING_LOCALE:-en-GB}"
AKAUNTING_APP_URL="${AKAUNTING_APP_URL:-}"
PG_ALLOWED_CIDR="${PG_ALLOWED_CIDR:-}"
ENABLE_HTTPS="${ENABLE_HTTPS:-0}"
AKAUNTING_DOMAIN="${AKAUNTING_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

if [[ "$ENABLE_HTTPS" == "1" && -z "$AKAUNTING_DOMAIN" ]]; then
  msg_error "ENABLE_HTTPS=1 requires AKAUNTING_DOMAIN to be set (e.g. AKAUNTING_DOMAIN=accounting.example.com)."
  exit 1
fi

[[ -z "$AKAUNTING_DB_PASSWORD" ]] && AKAUNTING_DB_PASSWORD="$(gen_secret)"
[[ -z "$AKAUNTING_ADMIN_PASSWORD" ]] && AKAUNTING_ADMIN_PASSWORD="$(gen_secret)"
[[ -z "$PG_ALLOWED_CIDR" ]] && PG_ALLOWED_CIDR="$(detect_default_cidr)"
# Default assumes direct IP:port access, or the Caddy-fronted domain if
# ENABLE_HTTPS=1. Override with whatever address an existing reverse proxy
# (Nginx Proxy Manager, ...) presents to clients instead - Laravel uses this
# for absolute links, redirects and email URLs.
if [[ -z "$AKAUNTING_APP_URL" ]]; then
  if [[ "$ENABLE_HTTPS" == "1" ]]; then
    AKAUNTING_APP_URL="https://${AKAUNTING_DOMAIN}"
  else
    AKAUNTING_APP_URL="http://$(get_ip):${AKAUNTING_PORT}"
  fi
fi

install_docker
install_postgres
configure_postgres
create_database
build_image
run_container true
wait_for_akaunting

if [[ "$ENABLE_HTTPS" == "1" ]]; then
  install_caddy
  confirm_https_ready
  msg_info "Starting Caddy (requesting the certificate now)"
  systemctl enable -q --now caddy
  wait_for_https
fi

msg_info "Setting up welcome message"
setup_motd
if [[ "${CONSOLE_AUTOLOGIN:-0}" == "1" ]]; then
  setup_console_autologin
  msg_ok "Configured welcome message (console autologin enabled)"
else
  msg_ok "Configured welcome message"
fi

cat <<EOF >"$STATE_FILE"
AKAUNTING_PORT=${AKAUNTING_PORT}
AKAUNTING_DB_NAME=${AKAUNTING_DB_NAME}
AKAUNTING_DB_USER=${AKAUNTING_DB_USER}
AKAUNTING_DB_PASSWORD=${AKAUNTING_DB_PASSWORD}
AKAUNTING_ADMIN_EMAIL=${AKAUNTING_ADMIN_EMAIL}
AKAUNTING_ADMIN_PASSWORD=${AKAUNTING_ADMIN_PASSWORD}
AKAUNTING_COMPANY_NAME=${AKAUNTING_COMPANY_NAME}
AKAUNTING_COMPANY_EMAIL=${AKAUNTING_COMPANY_EMAIL}
AKAUNTING_LOCALE=${AKAUNTING_LOCALE}
AKAUNTING_APP_URL=${AKAUNTING_APP_URL}
PG_ALLOWED_CIDR=${PG_ALLOWED_CIDR}
ENABLE_HTTPS=${ENABLE_HTTPS}
AKAUNTING_DOMAIN=${AKAUNTING_DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
EOF
chmod 600 "$STATE_FILE"

msg_info "Cleaning up"
apt-get -y -qq autoremove >/dev/null
apt-get -y -qq autoclean >/dev/null
msg_ok "Cleaned up"

print_summary
