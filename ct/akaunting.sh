#!/usr/bin/env bash
set -Eeuo pipefail

# Copyright (c) 2026 Akaunting-LXC contributors
# License: GPL-3.0 | https://github.com/trinityr/Akaunting-LXC/raw/main/LICENSE
# Source: https://akaunting.com/ | https://github.com/akaunting/docker
#
# Run on the Proxmox VE host shell. Creates a Debian 12 LXC container running
# Docker (for the Akaunting app) alongside a native PostgreSQL server, and
# wires the two together. Re-run in "update" mode against an existing
# container to pull the latest Akaunting release.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/trinityr/Akaunting-LXC/main/ct/akaunting.sh)"
#   bash -c "$(curl -fsSL .../ct/akaunting.sh)" -- update <CTID>
#
# Overridable via environment variables:
#   CTID, CT_HOSTNAME, CORES, RAM_MB, DISK_GB, BRIDGE, NET (dhcp or ip/cidr),
#   GATEWAY, TEMPLATE_STORAGE, CONTAINER_STORAGE, UNPRIVILEGED (1/0),
#   CONSOLE_AUTOLOGIN (1/0, default 0 - see README for the security tradeoff)
#   AKAUNTING_PORT (host port the web UI is published on, default 8080)
#   AKAUNTING_DB_NAME, AKAUNTING_DB_USER (defaults: akaunting / akaunting)
#   AKAUNTING_DB_PASSWORD (default: randomly generated)
#   AKAUNTING_ADMIN_EMAIL, AKAUNTING_ADMIN_PASSWORD (default: generated)
#   AKAUNTING_COMPANY_NAME, AKAUNTING_COMPANY_EMAIL, AKAUNTING_LOCALE
#   PG_ALLOWED_CIDR (network allowed to reach Postgres besides the
#   container's own docker bridge - see README for the security tradeoff)

INSTALL_SCRIPT_URL="${INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/trinityr/Akaunting-LXC/main/install/akaunting-install.sh}"

msg_info() { echo -e "  [*] $1"; }
msg_ok() { echo -e "  [+] $1"; }
msg_error() { echo -e "  [!] $1" >&2; }

# Fetches the install script into $INSTALL_SCRIPT_CONTENT, or exits on failure.
# Fetching (and validating) separately from execution avoids silently running
# an empty command if the download fails.
fetch_install_script() {
  INSTALL_SCRIPT_CONTENT="$(curl -fsSL "$INSTALL_SCRIPT_URL")" || {
    msg_error "Failed to download install script from ${INSTALL_SCRIPT_URL}"
    exit 1
  }
  if [[ -z "$INSTALL_SCRIPT_CONTENT" ]]; then
    msg_error "Install script downloaded from ${INSTALL_SCRIPT_URL} was empty"
    exit 1
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "This script must be run as root on the Proxmox VE host."
    exit 1
  fi
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "pveversion not found - this does not look like a Proxmox VE host."
    exit 1
  fi
}

run_update() {
  local ctid="$1"
  if ! pct status "$ctid" >/dev/null 2>&1; then
    msg_error "Container ${ctid} does not exist."
    exit 1
  fi
  fetch_install_script
  msg_info "Running update inside container ${ctid}"
  pct exec "$ctid" -- bash -c "$INSTALL_SCRIPT_CONTENT" akaunting-install.sh update
  msg_ok "Update complete"
}

run_install() {
  local CTID="${CTID:-$(pvesh get /cluster/nextid)}"
  local CT_HOSTNAME="${CT_HOSTNAME:-akaunting}"
  local CORES="${CORES:-2}"
  local RAM_MB="${RAM_MB:-4096}"
  local DISK_GB="${DISK_GB:-15}"
  local BRIDGE="${BRIDGE:-vmbr0}"
  local NET="${NET:-dhcp}"
  local GATEWAY="${GATEWAY:-}"
  local TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
  local CONTAINER_STORAGE="${CONTAINER_STORAGE:-local-lvm}"
  local UNPRIVILEGED="${UNPRIVILEGED:-1}"
  local CONSOLE_AUTOLOGIN="${CONSOLE_AUTOLOGIN:-0}"

  local AKAUNTING_PORT="${AKAUNTING_PORT:-8080}"
  local AKAUNTING_DB_NAME="${AKAUNTING_DB_NAME:-akaunting}"
  local AKAUNTING_DB_USER="${AKAUNTING_DB_USER:-akaunting}"
  local AKAUNTING_DB_PASSWORD="${AKAUNTING_DB_PASSWORD:-}"
  local AKAUNTING_ADMIN_EMAIL="${AKAUNTING_ADMIN_EMAIL:-admin@akaunting.local}"
  local AKAUNTING_ADMIN_PASSWORD="${AKAUNTING_ADMIN_PASSWORD:-}"
  local AKAUNTING_COMPANY_NAME="${AKAUNTING_COMPANY_NAME:-My Company}"
  local AKAUNTING_COMPANY_EMAIL="${AKAUNTING_COMPANY_EMAIL:-$AKAUNTING_ADMIN_EMAIL}"
  local AKAUNTING_LOCALE="${AKAUNTING_LOCALE:-en-GB}"
  local PG_ALLOWED_CIDR="${PG_ALLOWED_CIDR:-}"

  if pct status "$CTID" >/dev/null 2>&1; then
    msg_error "Container ID ${CTID} already exists. Set CTID to a free ID or run in update mode."
    exit 1
  fi

  msg_info "Refreshing available LXC templates"
  pveam update >/dev/null
  msg_ok "Refreshed template index"

  local TEMPLATE
  TEMPLATE=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-12-standard' | sort -V | tail -n1)
  if [[ -z "$TEMPLATE" ]]; then
    msg_error "Could not find a debian-12-standard template."
    exit 1
  fi
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_info "Downloading template ${TEMPLATE}"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null
    msg_ok "Downloaded template"
  else
    msg_ok "Template ${TEMPLATE} already present"
  fi

  local NET0="name=eth0,bridge=${BRIDGE},ip=${NET}"
  [[ -n "$GATEWAY" ]] && NET0="${NET0},gw=${GATEWAY}"

  msg_info "Creating container ${CTID} (${CT_HOSTNAME})"
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM_MB" \
    --swap 512 \
    --rootfs "${CONTAINER_STORAGE}:${DISK_GB}" \
    --net0 "$NET0" \
    --unprivileged "$UNPRIVILEGED" \
    --onboot 1 \
    --features keyctl=1,nesting=1 \
    --tags akaunting \
    >/dev/null
  msg_ok "Created container ${CTID}"

  msg_info "Starting container"
  pct start "$CTID"

  local tries=0
  local ip=""
  while [[ $tries -lt 30 ]]; do
    ip=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
    [[ -n "$ip" ]] && break
    sleep 2
    tries=$((tries + 1))
  done
  if [[ -z "$ip" ]]; then
    msg_error "Container did not obtain an IP address in time."
    exit 1
  fi
  msg_ok "Container is up at ${ip}"

  fetch_install_script
  msg_info "Installing Docker, PostgreSQL and Akaunting inside the container (this can take a few minutes)"
  pct exec "$CTID" -- env \
    "CONSOLE_AUTOLOGIN=${CONSOLE_AUTOLOGIN}" \
    "AKAUNTING_PORT=${AKAUNTING_PORT}" \
    "AKAUNTING_DB_NAME=${AKAUNTING_DB_NAME}" \
    "AKAUNTING_DB_USER=${AKAUNTING_DB_USER}" \
    "AKAUNTING_DB_PASSWORD=${AKAUNTING_DB_PASSWORD}" \
    "AKAUNTING_ADMIN_EMAIL=${AKAUNTING_ADMIN_EMAIL}" \
    "AKAUNTING_ADMIN_PASSWORD=${AKAUNTING_ADMIN_PASSWORD}" \
    "AKAUNTING_COMPANY_NAME=${AKAUNTING_COMPANY_NAME}" \
    "AKAUNTING_COMPANY_EMAIL=${AKAUNTING_COMPANY_EMAIL}" \
    "AKAUNTING_LOCALE=${AKAUNTING_LOCALE}" \
    "PG_ALLOWED_CIDR=${PG_ALLOWED_CIDR}" \
    bash -c "$INSTALL_SCRIPT_CONTENT"
  msg_ok "Installed Akaunting"

  echo
  echo "Akaunting setup complete. Full credential summary is printed above."
  echo "Web UI: http://${ip}:${AKAUNTING_PORT}"
  echo "PostgreSQL: ${ip}:5432 (also reachable at 127.0.0.1:5432 from inside the container)"
}

require_root

if [[ "${1:-}" == "update" ]]; then
  run_update "${2:?Usage: akaunting.sh update <CTID>}"
else
  run_install
fi
