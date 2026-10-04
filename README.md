# harbor

Reproducible, self-hosted [Harbor](https://goharbor.io/) container registry on Docker Compose.

The Harbor release is pinned in `upstream/VERSION` (currently **v2.15.2**). All settings live in
one `.env` file. `make setup` renders Harbor's `harbor.yml` from it and runs the official
`goharbor/prepare` tool, which generates `docker-compose.yml` and `common/config/` the same way
the upstream installer does. Small compose overrides adapt the result for a shared host. Secrets
are generated once and never regenerated, so the same `.env` and data directory always give you
the same registry.

- Two ways to serve it: behind an existing **Traefik** (default) or **standalone** with Harbor's own nginx and your TLS certificate
- Works with a Traefik that runs in Docker Swarm with only the swarm provider (`make traefik-config` prints a file-provider route)
- Trivy scanner, optional Prometheus metrics and Redis cache, outbound HTTP proxy, image mirror prefix
- `docker compose up --wait`, a healthcheck that asks Harbor for every component's health, backup/restore with `pg_dump`, one-command version pinning

## Requirements

- Linux server with Docker Engine and the Compose plugin **v2.24 or newer**, plus `openssl`, `curl` and `make`
- Root (or `sudo`): Harbor's prepare writes config files that only root can read
- 2+ vCPU, 4 GB RAM, and disk space for your images in `DATA_DIR`
- A DNS record for `HARBOR_HOSTNAME`, and a TLS certificate: from Traefik, or a file for standalone mode
- Pull access to the `goharbor/*` images (Docker Hub, or a mirror via `HARBOR_IMAGE_REGISTRY`)

## Quick start

```bash
git clone <this repository> /opt/harbor
cd /opt/harbor
make init                 # creates .env from .env.example
$EDITOR .env              # set HARBOR_HOSTNAME and PROXY_MODE (+ the Traefik or TLS settings)
sudo make deploy          # validate, generate secrets, prepare, pull, start, wait until healthy
```

Open `https://<HARBOR_HOSTNAME>` and log in as `admin` with `HARBOR_ADMIN_PASSWORD` from `.env`
(generated on the first run). Change it in the UI right away. Harbor applies the value from
`.env` only on the very first start. Then:

```bash
docker login <HARBOR_HOSTNAME>
docker push <HARBOR_HOSTNAME>/library/<image>:<tag>
```

Run `make` to list all commands.

## Configuration

`.env.example` documents every setting. `make setup` (also run by `make deploy`):

- validates `.env` and refuses placeholder values
- generates `HARBOR_DB_PASSWORD` and `HARBOR_ADMIN_PASSWORD` if they are empty, and writes them back into `.env`. It refuses to generate a new database password when the database already exists, because PostgreSQL keeps the original one. Restore `.env` from a backup instead.
- renders `harbor.yml` (mode 600) from `.env`, plus `config/harbor.extra.yml` if present (e.g. S3 storage, see the `.example`)
- runs `goharbor/prepare` only if `harbor.yml`, the image or the TLS files changed (`make prepare` forces a run). Prepare rotates Harbor's internal secrets, so the next `make deploy` then recreates all containers, which means a short downtime. Without changes, `make deploy` leaves running containers alone.
- sets `COMPOSE_FILE`, so plain `docker compose ...` commands work in this directory

It never touches running containers. Do not edit `harbor.yml`, `docker-compose.yml` or
`common/`; they are regenerated.

### Behind Traefik (`PROXY_MODE=traefik`, default)

Harbor's nginx publishes no ports and joins the external network `TRAEFIK_NETWORK` under the
DNS alias `TRAEFIK_ALIAS` (default `harbor-proxy`). Harbor uses `https://HARBOR_HOSTNAME` as
its external URL. One route to `http://harbor-proxy:8080` covers the UI, `/api`, `/v2`, `/service` and `/c`.

- **Traefik with the docker provider** (same host): the proxy container has the labels already. Set `TRAEFIK_ENTRYPOINT`, plus `TRAEFIK_CERTRESOLVER` / `TRAEFIK_MIDDLEWARES` as needed.
- **Traefik in Docker Swarm with only the swarm provider** ignores container labels. Run `make traefik-config` and save the output in Traefik's dynamic configuration directory, e.g. `traefik/dynamic/harbor.yml` in the infrastructure repo. `TRAEFIK_NETWORK` must be an *attachable* overlay network and Harbor must run on a node of that swarm; Traefik then reaches the container through the overlay, whichever node it runs on. Check with `docker network inspect -f '{{.Attachable}}' traefik-net` (`make deploy` checks it too). If it prints `false`, either recreate the network with `--attachable` (all stacks using it have to be removed first), or use `PROXY_MODE=standalone` with `BIND_ADDRESS` set to the host's private IP, `HTTP_PORT` to a free port and `EXTERNAL_URL=https://<HARBOR_HOSTNAME>`; `make traefik-config` then routes to that address.

Do not put buffering or request-size middlewares in front of Harbor; image layers can be several
GB. Traefik must not time out long uploads (`respondingTimeouts.readTimeout=0`).

### Standalone (`PROXY_MODE=standalone`)

Harbor's nginx publishes `BIND_ADDRESS:HTTP_PORT`. With `TLS_CERT` / `TLS_KEY` (absolute host
paths, full chain + key), it also serves `HTTPS_PORT` and redirects HTTP to HTTPS. A renewed
certificate is picked up by the next `make deploy`. Without TLS, Harbor runs over plain HTTP:
fine for a test on `localhost`, but other docker clients refuse it unless it is listed in their
`insecure-registries`.

### Images, proxy, Trivy

- `HARBOR_IMAGE_REGISTRY=registry.example.com/` pulls every `goharbor/*` image (including `prepare`) through a mirror
- `HARBOR_HTTP_PROXY` / `HARBOR_HTTPS_PROXY` / `HARBOR_NO_PROXY` are used by core, jobservice and Trivy for replication, proxy-cache projects and the Trivy DB
- Trivy downloads its vulnerability DB from `TRIVY_DB_REPOSITORY` (OCI). Point it at a mirror, or set `TRIVY_SKIP_UPDATE=1` on air-gapped hosts.

## Operations

| Command | Description |
|---|---|
| `make deploy` | Setup, pull, start/update, wait for healthy, healthcheck |
| `make status` | Healthcheck: containers healthy, `/api/v2.0/health` all green, public `/v2/` answers 401 (`ARGS=--local` skips the public check) |
| `make logs SERVICE=core` | Follow logs; per-component log files are also in `LOG_DIR` |
| `make ps` / `make down` / `make restart` | Container status / stop (data is kept) / restart |
| `make backup` | `.env` + database dump + `DATA_DIR/secret` (+ registry blobs with `BACKUP_REGISTRY=1`) into `BACKUP_DIR`, keeping `BACKUP_KEEP_DAYS` days |
| `make restore FILE=backups/harbor-….tar.gz` | Restore an archive; current files are kept with a `.before-restore-*` suffix |
| `make traefik-config` | File-provider route for a swarm-only Traefik |
| `make prepare` | Regenerate Harbor's configuration even if nothing changed |

Containers are named `harbor-<service>-1` (the generated fixed names such as `redis` or `nginx`
are removed so they cannot collide with other containers on the host).

### Backups

For daily backups, add a cron entry such as
`0 3 * * * cd /opt/harbor && bash scripts/backup.sh >> /var/log/harbor-backup.log 2>&1`.
**The archive contains all secrets.** Copy it off the server and treat it like a password.

Registry blobs are not in the archive by default because they can be huge. Either set
`BACKUP_REGISTRY=1`, or back up `DATA_DIR/registry` separately (e.g. `rsync`/snapshots), or
use S3 storage via `config/harbor.extra.yml`. A restore without blobs keeps whatever is already
in `DATA_DIR/registry`.

### Upgrading Harbor

```bash
make backup
make update-upstream                     # or VERSION=vX.Y.Z
git diff -- upstream/                    # new harbor.yml options? check the release notes
make deploy                              # prepare runs, core migrates the database on start
git commit -am "Harbor vX.Y.Z"
```

Read the [release notes](https://github.com/goharbor/harbor/releases) first: some upgrades must
go through an intermediate minor version.

### Moving to a new server

Install Docker, clone the repository, copy a backup archive (with registry blobs, or copy
`DATA_DIR/registry` separately), then run `sudo make restore FILE=... && sudo make deploy`.
Point DNS at the new server.

## Deploying with GitLab CI

`.gitlab-ci.yml` runs shellcheck on every push and has manual jobs `harbor_deploy`,
`harbor_status` and `harbor_backup` on the default branch. `harbor_deploy` rsyncs the
repository to `DEPLOY_PATH` over SSH and runs `scripts/deploy.sh` there as root. The server
keeps its own `.env`, data and generated files; the job never transfers or overwrites them.
The required variables are listed at the top of the file. Create `.env` on the server once
before the first run.

## Layout

```
.env.example                all settings, copied to .env (git-ignored)
config/harbor.extra.yml     optional extra harbor.yml settings (see the .example)
compose/common.yml          always: no fixed container names, proxy ports under our control
compose/standalone*.yml     PROXY_MODE=standalone (HTTP, + HTTPS with TLS_CERT)
compose/traefik*.yml        PROXY_MODE=traefik (network, alias, labels)
compose/trivy.yml           ENABLE_TRIVY=1
compose/metrics.yml         ENABLE_METRICS=1
scripts/                    setup, deploy, healthcheck, backup, restore, traefik-config, update-upstream
upstream/                   pinned VERSION, upstream harbor.yml.tmpl / prepare (reference), license
harbor.yml, docker-compose.yml, common/   generated by make setup (git-ignored)
data/, logs/, backups/      runtime state (git-ignored; DATA_DIR / LOG_DIR / BACKUP_DIR)
```

## License

Harbor is licensed under the Apache License 2.0 (`upstream/LICENSE`); the files in `upstream/`
come from [goharbor/harbor](https://github.com/goharbor/harbor).
