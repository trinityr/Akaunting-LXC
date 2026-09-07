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

  cat <<EOF >"$CRED_FILE"
Akaunting web UI : http://${ip}:${AKAUNTING_PORT}
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
PG_ALLOWED_CIDR="${PG_ALLOWED_CIDR:-}"

[[ -z "$AKAUNTING_DB_PASSWORD" ]] && AKAUNTING_DB_PASSWORD="$(gen_secret)"
[[ -z "$AKAUNTING_ADMIN_PASSWORD" ]] && AKAUNTING_ADMIN_PASSWORD="$(gen_secret)"
[[ -z "$PG_ALLOWED_CIDR" ]] && PG_ALLOWED_CIDR="$(detect_default_cidr)"

install_docker
install_postgres
configure_postgres
create_database
build_image
run_container true
wait_for_akaunting

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
PG_ALLOWED_CIDR=${PG_ALLOWED_CIDR}
EOF
chmod 600 "$STATE_FILE"

msg_info "Cleaning up"
apt-get -y -qq autoremove >/dev/null
apt-get -y -qq autoclean >/dev/null
msg_ok "Cleaned up"

print_summary
