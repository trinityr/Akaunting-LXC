# Akaunting-LXC

Deploy [Akaunting](https://akaunting.com/) — free, open source online accounting software — as a Proxmox VE LXC container, running the official Akaunting Docker image against a **native PostgreSQL server** installed alongside it.

## Why not just `docker run` the official image?

The [official `akaunting/akaunting` image](https://github.com/akaunting/docker) is built with only the `pdo_mysql` PHP extension — even though the Akaunting application itself fully supports PostgreSQL (`DB_CONNECTION=pgsql`), the shipped image can't actually speak to a Postgres server. This project works around that by building a tiny local layer on top of the upstream image that adds `pdo_pgsql`/`pgsql`, and pairs it with a real PostgreSQL server running directly on the container's OS (not dockerized), so it's easy to reach with `psql`, pgAdmin, or any other admin tool.

## Quick start

Run this in the Proxmox VE host shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/trinityr/Akaunting-LXC/main/ct/akaunting.sh)"
```

This creates a Debian 12 LXC container (2 vCPU / 4 GB RAM / 15 GB disk, DHCP on `vmbr0`, auto-picked container ID) and, inside it:

1. Installs Docker and PostgreSQL.
2. Configures PostgreSQL to listen on all interfaces and creates the `akaunting` database and role.
3. Builds a local `akaunting-pgsql:local` image (upstream `akaunting/akaunting:latest` + `pdo_pgsql`).
4. Runs that image with `DB_CONNECTION=pgsql`, pointed at the Postgres server via `host.docker.internal`, and drives Akaunting's non-interactive CLI installer to create the company and admin account on first boot.

Defaults can be overridden with environment variables, e.g.:

```bash
CTID=210 CT_HOSTNAME=accounting AKAUNTING_PORT=8081 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/trinityr/Akaunting-LXC/main/ct/akaunting.sh)"
```

Available variables:

| Variable | Default | Purpose |
|---|---|---|
| `CTID` | next free ID | Container ID |
| `CT_HOSTNAME` | `akaunting` | Container hostname |
| `CORES` / `RAM_MB` / `DISK_GB` | `2` / `4096` / `15` | Container sizing |
| `BRIDGE` / `NET` / `GATEWAY` | `vmbr0` / `dhcp` / — | Networking |
| `TEMPLATE_STORAGE` / `CONTAINER_STORAGE` | `local` / `local-lvm` | Storage targets |
| `UNPRIVILEGED` | `1` | Unprivileged LXC |
| `CONSOLE_AUTOLOGIN` | `0` | See [Console access](#console-access) |
| `AKAUNTING_PORT` | `8080` | Host port the web UI is published on |
| `AKAUNTING_DB_NAME` / `AKAUNTING_DB_USER` | `akaunting` / `akaunting` | Postgres database/role |
| `AKAUNTING_DB_PASSWORD` | generated | Postgres role password |
| `AKAUNTING_ADMIN_EMAIL` / `AKAUNTING_ADMIN_PASSWORD` | `admin@akaunting.local` / generated | Akaunting admin login |
| `AKAUNTING_COMPANY_NAME` / `AKAUNTING_COMPANY_EMAIL` | `My Company` / admin email | First company created |
| `AKAUNTING_LOCALE` | `en-GB` | Install locale |
| `PG_ALLOWED_CIDR` | container's own `/24` | See [PostgreSQL access](#postgresql-access) |

All generated credentials (database and admin) are printed at the end of setup and saved to `/root/akaunting-credentials.txt` (root-only) inside the container.

## Accessing Akaunting

- Web UI: `http://<container-ip>:<AKAUNTING_PORT>` (default port `8080`)
- Admin login: printed at the end of setup / in `/root/akaunting-credentials.txt`

The container's `/etc/motd` is refreshed on every boot with its OS version, PostgreSQL version, IPv4/IPv6 addresses, and the web UI URL. It displays after a successful login — over SSH (once you've configured SSH access into the container, which this script doesn't set up), or on the console after entering credentials. It does **not** show via `pct enter`/`pct exec`, since those attach directly and skip the login flow that triggers it.

## PostgreSQL access

PostgreSQL runs directly on the container (not in Docker) and listens on all interfaces so it's usable both by the Akaunting container and by you, for administration:

- From inside the container: `127.0.0.1:5432`
- From the LAN: `<container-ip>:5432`, if your client's address falls inside `PG_ALLOWED_CIDR` (default: the `/24` network containing the container's own IP — e.g. a container at `192.168.1.50` allows `192.168.1.0/24`)
- The Docker bridge network (`172.16.0.0/12`) is always allowed, since the Akaunting container needs it regardless of `PG_ALLOWED_CIDR`

All connections still require the role's password (`scram-sha-256`), so opening this up doesn't mean anonymous access — but it does mean anyone who can reach the container on your network can attempt to authenticate. Set `PG_ALLOWED_CIDR=127.0.0.1/32` at install time if you don't want LAN-wide reachability, or a narrower/wider CIDR to match your network.

Connect with, e.g.:

```bash
psql "postgresql://akaunting:<password>@<container-ip>:5432/akaunting"
```

## Console access

By default, `pct console <CTID>` (and the Proxmox web console) drops you at a normal login prompt — no root password is set by this script, so you'd need to set one yourself (`pct exec <CTID> -- passwd`) to log in there.

Setting `CONSOLE_AUTOLOGIN=1` at install time instead configures the console (tty1) to automatically log in as root with no password — which also makes the MOTD visible immediately on opening the console, without needing any credentials for the container at all. This is **off by default**: it means anyone who can open this container's console in Proxmox gets an instant root shell. Reasonable if Proxmox access is already your trust boundary (e.g. a personal homelab); skip it if the container needs to stay locked down independently of who can reach the Proxmox UI.

## Updating

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/trinityr/Akaunting-LXC/main/ct/akaunting.sh)" update <CTID>
```

Pulls the latest `akaunting/akaunting` image, rebuilds the local `pdo_pgsql` layer on top of it, and redeploys the container against the existing database and `akaunting-data` volume (which holds Akaunting's `storage/` — uploads, config, cache). PostgreSQL itself and its data are untouched. Credentials are reused from `/root/akaunting.env` inside the container, so you won't need to re-supply them.

## How it works

- [`ct/akaunting.sh`](ct/akaunting.sh) — run on the Proxmox host. Creates the LXC (`pct create`/`pct start`) and hands off to the install script inside it, or drives an update against an existing container.
- [`install/akaunting-install.sh`](install/akaunting-install.sh) — run inside the container. Installs Docker and PostgreSQL, creates the database/role, builds the `pdo_pgsql`-patched Akaunting image, and runs it.

Both scripts are self-contained (no dependency on other Proxmox helper-script frameworks) and safe to re-read before running, since they're fetched and executed via `curl | bash`.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE). Akaunting is a trademark of Akaunting S.L.
