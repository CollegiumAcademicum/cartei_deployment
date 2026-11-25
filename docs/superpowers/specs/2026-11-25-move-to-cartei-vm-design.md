# Move CArtei from pod0 to the cartei VM — design

Date: 2026-11-25 · Status: draft, awaiting approval

## Why

CArtei is a protected resource. For opsec it moves off the shared **pod0** (10.10.1.200) onto its own hardened VM **cartei** (`cartei.intranet.ca-hd.de`, 10.10.1.131, Rocky 9; built and hardened 2026-11-25, see `ca_intranet` PR #10). Only `admins`, `cartei_admin` and local `core` can log in there. Its firewall allows SSH/HTTP/HTTPS only from 10.1.0.0/16 and 10.10.0.0/16.

## Goals

- CArtei (Postgres 16, `migrate` + `app`, Vision, backup/update/Vision timers) runs on the cartei VM with the same data, and nothing of it runs on pod0.
- TLS for `cartei.ca-hd.de` terminates on the cartei VM, not pod0's shared Caddy.
- pod0 cleaned of CArtei after a rollback window.

## Non-goals

- Rotating secrets. Copied as-is (user, 2026-11-25). The world-readable `.env` files on pod0 were `chmod 600`'d the same day.
- Converting to Quadlets (possible later project).
- Recovering real client IPs (ingress is L4 passthrough; unchanged).

## Anti-goals

- Data loss or a split brain (writes landing on pod0 after the copy).
- Ports published by Podman that bypass the VM's firewalld zone.
- Failed ACME attempts piling up for `cartei.ca-hd.de` (rate limits).

## Decisions (user)

| Topic | Decision |
|---|---|
| Approach | Move the existing compose + systemd setup as-is, add Caddy (option 1 of 3; not Quadlets, not a path rename). |
| Path | Keep `/tank/cartei` (a plain directory on the VM's root disk, as on pod0 — not a ZFS/virtiofs share). |
| Secrets | Copy as-is, no rotation. |
| When | Now, no announcement. A few minutes of downtime. |

## Approaches considered

1. **Move as-is + Caddy on the host network — chosen.** Least change, every step already proven on pod0.
2. Convert to Quadlets: cleaner long-term, but rewrites the whole deployment at the same time as moving it.
3. Option 1 with `/srv/cartei`: touches every unit, script and doc for a cosmetic gain.

## Design

### Repo changes (`cartei_deployment`, one PR, merged before the VM setup)

- `docker-compose.yaml`: `app` drops the external `systemd-caddy` network and publishes **`127.0.0.1:8000:8000`**. New service **`caddy`** (`docker.io/library/caddy:2`, **`network_mode: host`**, `./Caddyfile:/etc/caddy/Caddyfile:ro,z`, `./data/caddy:/data:z`, `depends_on: app`, `restart: unless-stopped`). It's pulled by the existing nightly update timer.
- `Caddyfile` (new): global `email it@ca-hd.de`; `cartei.ca-hd.de { reverse_proxy 127.0.0.1:8000 }`.
- Host networking is why it's safe: Caddy binds 80/443 on the host, so the VM's `cartei-internal` firewalld zone filters them. Ports published by Podman would be DNAT'd by netavark's own nftables rules, around the zone. The app's only port is on 127.0.0.1.
- `.gitignore`: add `data/caddy/`.
- `setup.sh`: `mkdir -p data/caddy`. Next-steps text: no external Caddy step.
- `operations.md`, `setup-db.sh` header, compose comment: "pod0 + shared Caddy" → "cartei VM + own Caddy".
- pod0 is unaffected by merging: its checkout isn't pulled (the update timer only pulls images).

### Preparation on the cartei VM (no downtime)

- Packages: EPEL, then `podman-compose age rclone git policycoreutils-python-utils` (`podman` is already there).
- Run `setup-db.sh` and `setup.sh` from `main` (both clone into `/tank/cartei`, create `data/`, apply SELinux contexts, install units and timers).
  - `setup-db.sh` starts the backup and Vision timers right away. Harmless: the first runs are at 03:30/04:30, after the switchover.
- Copy **`.env`, `vision.env`, `rclone.conf`** from pod0 (root-only files) with a direct pod0 → cartei pipe. The admin runs it on pod0 with their forwarded agent: `sudo tar -C /tank/cartei -cf - .env vision.env rclone.conf | ssh core@10.10.1.131 'sudo tar -C /tank/cartei -xf -'`, then `chmod 600` on the VM and `restorecon -Rv /tank/cartei`. All paths in `.env` (`RCLONE_CONFIG`, `LDAP_CA_CERT_PATH`, container names in `DATABASE_URL`) are the same on both hosts.
- Pull all images (`podman compose -f docker-compose.db.yaml pull`, `podman compose pull`, `podman pull ghcr.io/collegiumacademicum/cartei-vision:latest`). The GHCR packages are public (checked 2026-11-25), so no login is needed.

### Pre-flight (read-only, pod0, needs root)

- Nothing else uses CArtei's DB: `sudo podman ps --filter network=cartei_default --format '{{.Names}}'` should list only `cartei_postgres_1`, `cartei_app_1` (and `cartei_migrate_1` if present). Port 5432 is bound to 127.0.0.1, so only pod0-local clients are possible.

### Switchover (downtime starts)

1. **pod0:** `sudo systemctl disable --now cartei.service cartei-db.service cartei-backup.timer cartei-update.timer cartei-vision.timer`. This stops writes, and the 03:30 backup can no longer restart the DB (`Requires=cartei-db.service`).
2. **Copy the database directory** with Postgres stopped, so the copy is exact: roles (incl. `cartei_vision`), extensions, triggers. Same pipe as above: `sudo tar -C /tank/cartei/data --numeric-owner -cf - postgres | ssh core@10.10.1.131 'sudo tar -C /tank/cartei/data --numeric-owner -xf -'`. The data is small (daily dumps are ~4 MB). *Claude's call over `pg_dump`:* a single-DB dump misses cluster roles, and both sides run `postgres:16`.
3. **VM:** `systemctl start cartei-db.service`, then check that `pg_isready` passes and the row count of `tenant` matches the number noted on pod0 before stopping.
4. **Ingress (ca-ingress):** in `/srv/containers/ingress/nginx.conf`, change `cartei.ca-hd.de 10.10.1.200:443` and `:80` (2 lines) to `10.10.1.131`. Keep a timestamped `.bak` like the existing ones. Write the file **in place** (`sed … backup | tee nginx.conf`), because it's a single-file bind mount and `sed -i` would swap the inode under the container. Then `podman exec ingress nginx -t && podman exec ingress nginx -s reload`.
5. **VM:** `systemctl start cartei.service` (migrate → app → caddy). Starting Caddy only after the ingress points here means its first ACME attempt succeeds.

### Verification

- `https://cartei.ca-hd.de` serves a valid cert from the VM. Keycloak login works, and the dashboard + tenant list load.
- `sudo podman logs cartei_caddy_1` shows the cert obtained, no ACME errors.
- Test mail from the new IP: `sudo podman exec cartei_app_1 python manage.py sendtestemail <you>` arrives. If the SMTP server rejects the new IP, that's a finding to fix, not a rollback reason (mail is not on the critical path).
- One backup by hand: `sudo systemctl start cartei-backup.service`, then a new `.age` file in `/var/backup/cartei/` and in `rclone ls $R2_REMOTE`.
- Vision once: `sudo systemctl start cartei-vision.service` exits 0.
- Timers listed: backup 03:30, update 04:00, Vision 04:30.
- From outside the trusted nets, port 8000 isn't reachable (it isn't even on the LAN interface: `ss -tlnp` shows `127.0.0.1:8000`).

### Rollback (until pod0 is cleaned)

VM: `systemctl stop cartei.service cartei-db.service`. Ingress: restore the `.bak`, reload. pod0: `systemctl enable --now cartei-db.service cartei.service` + the three timers. Any writes made on the VM after the switch would be lost, so roll back only within the first hour, or copy the data back the same way.

### pod0 cleanup (after 7 days, *Claude's call*)

Remove the units/timers/Quadlet from `/etc/systemd/system` and `/etc/containers/systemd`, the `cartei.ca-hd.de` block from `/tank/caddy/Caddyfile` (reload Caddy), the `/tank/cartei` directory (data, `.env*`, `vision.env`, `rclone.conf`), `/var/backup/cartei` (R2 keeps the history), and the CArtei images. Remove `~/cartei` symlinks.

## Findings from the review (2026-11-25)

- **Documents aren't in R2.** `backup.sh` excludes the data of `enrollment_proof` and the six `*_document` tables. After pod0 is cleaned, the VM disk is the only copy of uploaded documents. So the pod0 cleanup waits until VM 131 is covered by a VM-level backup on pve0 (open question to the user).
- ca-ingress connects from 10.10.0.12, without PROXY protocol, so it's inside `cartei-internal` and Caddy needs no listener wrapper.
- `cartei.ca-hd.de` resolves to the public IP everywhere (no internal DNS shortcut to pod0).
- *Claude's call:* the VM runs pod0's exact `postgres:16` image (pulled by digest and tagged `postgres:16`), so the copied data directory sees the same glibc collations.
- *Claude's call:* pod0's Caddy loses its `cartei.ca-hd.de` block **at switchover** (not after 7 days), so it doesn't fail ACME renewals. Rollback re-adds it.
- *Claude's call:* the prep phase checks from the VM that R2 (`rclone lsf`) and the SMTP port are reachable, before any downtime.

## Left to the builder

Exact command order within each phase, the wording of doc updates, and how the row-count check is phrased.
