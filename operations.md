# CArtei — Operations

Runbook for deploying and running CArtei. Runtime is **Podman + systemd** on
two VMs. All commands assume the deploy dir `/srv/containers/www/home/cartei` (symlinked `~/cartei`).

## Architecture

| VM | systemd unit | Runs | Compose file |
|----|--------------|------|--------------|
| **DB VM** | `cartei-db.service` | PostgreSQL 16 | `docker-compose.db.yaml` |
| **App VM** | `cartei.service` | `migrate` container (Alembic), then `app` (Django + gunicorn) | `docker-compose.yaml` |

The `app` container depends on `migrate`: on every start, `migrate` runs the
`cartei_db` Alembic migrations to `head`, then `app` boots. App images come
from `ghcr.io/collegiumacademicum/` (`cartei-web`, `cartei-db`); the DB VM uses
stock `docker.io/postgres:16`.

### Client IPs are not visible to the app

Inbound HTTPS is routed by the org **ingress VM** (`10.10.0.12`) using nginx
`stream` + `ssl_preread` — a layer-4 SNI passthrough that never decrypts TLS and
opens a fresh TCP connection to the backend. So it cannot set `X-Forwarded-For`,
and every downstream (including the `www.intranet` box where cartei's TLS
terminates) sees the source IP as the ingress, `10.10.0.12`. That is why the
admin session list shows `10.10.0.12` for every session — the real client IP is
lost at the ingress and no app behind it can recover it.

This is cosmetic only (the IP is never used for auth). Recovering real client
IPs would require enabling the **PROXY protocol** on the shared ingress stream
server, which applies to *every* service it fronts (office, cloud, mattermost,
gitlab, …) and would break any backend not configured to accept it — an
org-wide change, not a cartei one. Until then, use **User-Agent** (which does
pass through, decrypted at `www.intranet`) plus login time to tell sessions
apart.

Images are pushed by each repo's `docker.yaml` workflow using the built-in
`GITHUB_TOKEN` (no Docker Hub secrets). If the GHCR packages are **private**,
the VMs must authenticate before pulling — once per VM:
```bash
echo "$GHCR_PAT" | podman login ghcr.io -u <github-user> --password-stdin
```
(`$GHCR_PAT` = a classic PAT with `read:packages`). Making the packages public
in the org's package settings removes this step.

## Initial setup

Both scripts are idempotent and clone/update the repo into `/srv/containers/www/home/cartei`.

**DB VM:**
```bash
curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/cartei_deployment/main/setup-db.sh | bash
nano /srv/containers/www/home/cartei/.env          # POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
podman compose -f docker-compose.db.yaml pull
systemctl start cartei-db.service
```
Then **firewall port 5432 to the app VM's IP only** — the DB port is published on the host.

**App VM:**
```bash
curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/cartei_deployment/main/setup.sh | bash
nano /srv/containers/www/home/cartei/.env          # fill every CHANGE_ME (incl. DATABASE_URL → DB VM)
podman compose pull
systemctl start cartei.service
```

Both `setup*.sh` also install and enable their systemd units: the update timer
on the app VM, the backup timer on the DB VM.

## Day-to-day

```bash
systemctl status cartei.service        # or cartei-db.service on the DB VM
bash ~/cartei/start.sh                  # pull images + start (app VM)
bash ~/cartei/stop.sh                   # stop
podman compose logs -f app             # app logs  (migrate logs: logs migrate)
podman compose -f docker-compose.db.yaml logs -f postgres   # DB VM
```

## Updates

App images are pulled and the service restarted **nightly at 04:00** via
`cartei-update.timer` (`pull` → `restart cartei.service`, which re-runs
migrations) — after the 03:30 backup so a bad update can be restored. Manual:
```bash
podman compose pull && systemctl restart cartei.service
```
The DB VM has no update timer — Postgres is pinned to `16`; update it
deliberately with `podman compose -f docker-compose.db.yaml pull && systemctl restart cartei-db.service`.

## DB migrations

Migrations live in the **`cartei_db`** repo and run automatically via the
`migrate` container on every app start/restart. To apply manually (e.g. during
development against a running DB):
```bash
cd cartei_db
DATABASE_URL=... uv run alembic upgrade head
```

## Backups

Runs on the **DB VM**. `cartei-backup.timer` fires `backup.sh` **daily at 03:30**
(`cartei-backup.service`, config loaded from `.env`). Each run:

```
pg_dump → gzip → age -r $AGE_RECIPIENT → /var/backup/cartei/<ts>.sql.gz.age → rclone → R2
```

- Encrypted with **age** (asymmetric): the DB VM holds only the *public* key, so a
  compromised server or R2 bucket cannot decrypt any backup. Only the offline
  private key can. Encryption is **mandatory** — if `AGE_RECIPIENT` is unset the
  backup aborts rather than writing plaintext.
- Local retention: `BACKUP_RETENTION_DAYS` (default 90). Remote retention: an R2
  **bucket lifecycle rule** (below) — the script does not prune R2.

Manual backup: `sudo /srv/containers/www/home/cartei/backup.sh`

Self-check (age round-trip + prune logic, no DB/R2): `./test-backup.sh`

### One-time setup

**1. Encryption key** — generate the keypair **on your workstation, not the server**:
```bash
age-keygen -o cartei-backup-key.txt          # store this file in a password manager
```
Copy the `# public key: age1...` value into `AGE_RECIPIENT` in `/srv/containers/www/home/cartei/.env`
on the DB VM. The private key file never touches the server.

**2. Cloudflare R2** — create a bucket and an R2 API token (Object Read & Write),
then configure the rclone remote on the DB VM. Either copy the template:
```bash
cp /srv/containers/www/home/cartei/rclone.conf.example /srv/containers/www/home/cartei/rclone.conf   # fill in token + endpoint
chmod 600 /srv/containers/www/home/cartei/rclone.conf
```
or run it interactively (`RCLONE_CONFIG=/srv/containers/www/home/cartei/rclone.conf rclone config` →
name `r2`, storage `s3`, provider `Cloudflare`, endpoint
`https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, region `auto`).

Set `R2_REMOTE=r2:<bucket>` and `RCLONE_CONFIG=/srv/containers/www/home/cartei/rclone.conf` in `.env`
(the `r2` prefix must match the remote name in `rclone.conf`).

**3. Remote retention** — in the R2 dashboard add a lifecycle rule to expire objects
after N days (matches local retention; keeps R2 from growing forever).

**SELinux (CentOS/RHEL):** `setup-db.sh` relabels the deploy dir so systemd can read
`.env` (`etc_t`) and exec `backup.sh` (`bin_t`) — files under `/srv/containers/www/home/cartei`
default to `var_t`, which `init_t` won't read/exec directly. After a `git pull`
that adds files, re-run
`sudo restorecon -Rv /srv/containers/www/home/cartei` (or `sudo bash setup-db.sh`).

Verify after the first run:
```bash
ls -lh /var/backup/cartei/
sudo journalctl -u cartei-backup.service --no-pager | tail
rclone ls r2:cartei-backups
```

### Restore

Fetch the dump (from R2 or local), then decrypt with the **offline private key** and
pipe into psql:
```bash
rclone copyto r2:cartei-backups/2026-08-09_033000.sql.gz.age ./restore.sql.gz.age   # or use a local file
age -d -i cartei-backup-key.txt restore.sql.gz.age | gunzip \
  | podman exec -i cartei_postgres_1 psql -U cartei cartei
```

## LDAP account provisioning & email SSOT

The **DB (`tenant.email`) is the source of truth** for a tenant's email; FreeIPA
`mail` is a downstream replica CArtei writes. Mietverwaltung creates the tenant
first, then provisions a FreeIPA account from the DB row via the "Intranet-Account
anlegen" button (CArtei → IPA JSON-RPC, `app/ldap_utils.provision_ldap_account`).
Provisioning needs these `.env` vars on the app VM:

```
IPA_SERVER=ipa.intranet.ca-hd.de
IPA_PROVISION_USER=svc-cartei
IPA_PROVISION_PASSWORD=...
IPA_VERIFY_SSL=true
```

The `svc-cartei` service account must get a **least-privilege** role — **not** the
stock "User Administrators" privilege, which also grants password resets, SSH-key
management and full `user-mod`. CArtei only needs to add users and write `mail`:

```bash
# add-user (default perm; handles DNA uidNumber, krb principal, etc.)
#   -> built-in "System: Add Users"
# user-add also creates a User Private Group, which needs read on the UPG
# Managed-Entries definition -> built-in "System: Read UPG Definition"
#   (without it: "Insufficient access: Could not read UPG Definition originfilter")
# ...and adds the user to the default group (ipausers), writing its member attr
#   -> built-in "System: Add user to default group"
#   (without it: "Insufficient 'write' privilege to the 'member' attribute of
#    entry 'cn=ipausers,...'")
# user-add --random also SETS a password -> needs "System: Change User password"
#   (without it the user entry is created but the call errors on the password
#    step: account exists, CArtei never links it, no welcome mail)
# write ONLY the mail attribute (for CArtei -> LDAP email write-through)
ipa permission-add 'CArtei: Modify user mail' --type=user --attrs=mail --right=write

ipa privilege-add 'CArtei Provisioning'
ipa privilege-add-permission 'CArtei Provisioning' \
  --permissions='System: Add Users' \
  --permissions='System: Read UPG Definition' \
  --permissions='System: Add user to default group' \
  --permissions='System: Change User password' \
  --permissions='CArtei: Modify user mail'
ipa role-add 'CArtei Provisioner'
ipa role-add-privilege 'CArtei Provisioner' --privileges='CArtei Provisioning'
# svc-cartei is a dedicated FreeIPA *user* (password auth, IPA JSON-RPC login) —
# a separate identity from the read-only LDAP bind account. Not a host/service.
ipa role-add-member  'CArtei Provisioner' --users=svc-cartei
```

NOT granted (deliberately): `System: Modify Users`, `System: Manage User SSH Public
Keys`, certificate perms, `System: Remove Users`.
`System: Change User password` IS granted — `user-add --random` sets the one-time
password as part of the add, which requires it. This is the one sensitive
capability the account holds (it can set/reset user passwords); emailing a temp
password to a new tenant is impossible without it. The password is set expired, so
the tenant must change it on first login; CArtei receives it for onboarding delivery.

**Lock `mail` self-service in FreeIPA** so tenants can't edit their own email out
of band (all edits must flow through CArtei → DB → LDAP):

```bash
# remove the mail attribute from the default self-service permission
ipa selfservice-mod "Self can write own record" \
  --attrs=givenname --attrs=sn --attrs=... # list WITHOUT mail
# (or: ipa selfservice-find  → copy the current --attrs, drop 'mail', re-apply)
```

This does **not** stop a directory *admin* from editing `mail` (admins bypass
self-service ACIs). That case is caught, not prevented, by the nightly drift
check: `cartei-drift-check.timer` fires `check_email_drift` **daily at 04:00**
(`podman compose exec app python manage.py check_email_drift`), logging any tenant
whose FreeIPA mail diverged from the DB. It only reports — correcting drift is a
human decision. Enable with `systemctl enable --now cartei-drift-check.timer`.

## Impersonation access

Impersonation is gated by the LDAP group in `CARTEI_IMPERSONATION_GROUP`
(default `cn=cartei_impersonation,...`). On every LDAP login `_sync_groups` maps
it to the `cartei_impersonation` Django group, granting/revoking by membership
just like the other rights groups. It is a **plain group, not `is_superuser`** —
so it confers exactly one capability and nothing implicit. Grant/revoke by
managing FreeIPA membership; no `auth_user` edits or redeploys needed.

```bash
ipa group-add cartei_impersonation --desc "CArtei: user impersonation"
ipa group-add-member cartei_impersonation --users=<uid>    # grant (effective next login)
ipa group-remove-member cartei_impersonation --users=<uid> # revoke (effective next login)
```

Membership grants exactly one thing: user impersonation (the "Benutzerübernahme"
navbar link → start/stop). It does **not** grant Mietverwaltung/admin/cluster
capabilities — those come from the other `CARTEI_*_GROUP` role groups. We
deliberately avoid Django's `is_superuser` for this: it is a loaded flag that the
Django admin, DRF, and many packages honor implicitly, so a plain group keeps the
blast radius to just the checks that name it.

Caveat: impersonation means "act as any member who is not themselves in
`cartei_impersonation`," so a member can assume e.g. a Mietverwaltung user's
session and wield that user's rights for the session. It grants only the
impersonation entry point, but that is itself high-privilege — keep membership
tight. Every start and stop is recorded in the append-only `impersonation_event`
audit table.

The local dev account (`seed_dev_data`) is added to this group so impersonation
can be exercised locally; it authenticates via Django's ModelBackend, not LDAP,
so the login sync never touches it.

## cartei_vision (enrollment-proof auto-verification)

Runs on the **DB VM** as a nightly one-shot Podman Quadlet, installed by
`setup-db.sh` (`cartei-vision.container` → generated `cartei-vision.service`,
fired by `cartei-vision.timer` at 04:30). Image:
`ghcr.io/collegiumacademicum/cartei-vision:latest` (built from `cartei_vision` +
`cartei_db` by that repo's `docker.yaml` workflow). The quadlet sets
`Pull=newer`, so each nightly run pulls a fresh image itself — the DB VM needs
no update timer. Trust anchors are baked into the image; no host trust dir is
needed.

One-time setup — create the least-privilege role and set its password:
```bash
# grant/revoke SQL lives in cartei_db (least-priv role for cartei_vision)
podman exec -i cartei_postgres_1 psql -U cartei cartei -c \
  "ALTER ROLE cartei_vision LOGIN PASSWORD 'CHANGE_ME';"
nano /srv/containers/www/home/cartei/vision.env      # DATABASE_URL with that password
```

Run manually / check:
```bash
sudo systemctl start cartei-vision.service
sudo journalctl -u cartei-vision.service --no-pager | tail
systemctl list-timers cartei-vision.timer
```
