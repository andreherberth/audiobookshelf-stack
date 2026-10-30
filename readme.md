# Audiobookshelf + Hetzner storage + Caddy

A Docker/Podman Compose stack for deploying [Audiobookshelf](https://www.audiobookshelf.org/) with media on **Hetzner Object Storage (S3)** or a **Hetzner Storage Box**, and Caddy as the default reverse proxy.

Built for small VPS disks: your library stays on Hetzner. This stack **FUSE-mounts** the remote with [rclone](https://rclone.org/) (`rclone mount`) — it does **not** sync or mirror the library onto the VPS. Local disk only holds:

- Audiobookshelf `/config` (SQLite) and `/metadata`
- A **bounded** rclone VFS cache (default 2G per mount) used while streaming/scanning

## Quick start — Object Storage (S3)

1. Create a [Hetzner Object Storage](https://docs.hetzner.com/storage/object-storage/) bucket and S3 credentials.
2. Copy and edit the environment file:

   ```bash
   cp .env.example .env
   # Set S3_ACCESS_KEY, S3_SECRET_KEY, S3_REGION, S3_ENDPOINT, S3_BUCKET
   # Leave STORAGE_BACKEND=objectstorage
   # Tune VFS_CACHE_MAX_SIZE if the VPS disk is tight (default 2G)
   ```

3. Create local data directories:

   ```bash
   mkdir -p data/config data/metadata
   ```

4. Start the stack (rclone mounts the bucket; nothing is synced down):

   ```bash
   docker compose up -d
   ```

5. Open your instance (e.g. `https://books.example.com` or `http://localhost` if `DOMAIN=:80`).
6. In Audiobookshelf, add a library pointing at `/audiobooks` (and optionally `/podcasts`, `/ebooks`).

Upload media **to Hetzner** (from your PC or another machine — not a VPS sync job):

```bash
rclone copy ./my-book/ hetzner:my-audiobooks/audiobooks/my-book/
```

## Quick start — Storage Box (SFTP mount)

1. Create a [Hetzner Storage Box](https://docs.hetzner.com/storage/storage-box/) and **enable SSH support** in Hetzner Console.
2. Copy and edit the environment file:

   ```bash
   cp .env.example .env
   # Set STORAGE_BACKEND=storagebox
   # Set STORAGEBOX_HOST, STORAGEBOX_USER, STORAGEBOX_PORT (default 23)
   ./scripts/obscure-password.sh 'your-storagebox-password'
   # Paste the output into STORAGEBOX_PASS=
   ```

3. Create folders on the Storage Box (`audiobooks`, and optionally `podcasts` / `ebooks`), then start with the Storage Box overlay:

   ```bash
   mkdir -p data/config data/metadata
   docker compose -f compose.yml -f compose.storagebox.yml up -d
   ```

   That runs `rclone mount` over SFTP into `/audiobooks` (FUSE). Files remain on the Storage Box.

4. In Audiobookshelf, add libraries pointing at `/audiobooks` (and optionally `/podcasts`, `/ebooks`).

Upload media **to the Storage Box** from elsewhere (PC, another host). Examples:

```bash
# rclone (SFTP remote named storagebox)
rclone copy ./my-book/ storagebox:audiobooks/my-book/

# or rsync over SSH port 23
rsync -e 'ssh -p23' -av ./my-book/ uXXXXX@uXXXXX.your-storagebox.de:audiobooks/my-book/
```

Storage Box accounts allow a limited number of simultaneous connections (typically 10). The Storage Box overlay caps rclone checkers to stay within that limit. If the box rejects the password or blocks this server, the mount script waits (`STORAGEBOX_AUTH_BACKOFF`, default 10 minutes, or `STORAGEBOX_BAN_BACKOFF`, default 15 minutes) instead of reconnecting immediately. Podcast and ebook mounts start only after the audiobooks mount is healthy.

## Compose files

| File | Description |
|------|-------------|
| `compose.yml` | **Default** — Object Storage FUSE mount + Audiobookshelf + Caddy |
| `compose.core.yml` | Sidecar stack without proxy (exposes port `13378`) |
| `compose.storagebox.yml` | Overlay — mounts Storage Box via SFTP instead of S3 |
| `compose.coolify.yml` | **Coolify 4.5+** — Object Storage mount (no Caddy / no custom networks) |
| `compose.coolify.storagebox.yml` | **Coolify 4.5+** — Storage Box SFTP mount |
| `compose.caddy.yml` | Caddy overlay — pairs with any core file |
| `compose.rclone-plugin.yml` | Plugin stack + Caddy (all-in-one) |
| `compose.rclone-plugin.core.yml` | Plugin stack without proxy |
| `compose.rclone-plugin.caddy.yml` | Caddy overlay for plugin core |

### Sidecar (recommended for Docker and Podman)

Uses an rclone container with FUSE. No host plugin install required.

```bash
# Object Storage — all-in-one with Caddy
docker compose up -d

# Storage Box — all-in-one with Caddy
docker compose -f compose.yml -f compose.storagebox.yml up -d

# Modular — no proxy
docker compose -f compose.core.yml up -d
docker compose -f compose.core.yml -f compose.storagebox.yml up -d

# Modular — with Caddy
docker compose -f compose.core.yml -f compose.caddy.yml up -d
docker compose -f compose.core.yml -f compose.storagebox.yml -f compose.caddy.yml up -d

# Optional podcast / ebook libraries
docker compose --profile podcasts --profile ebooks up -d
docker compose -f compose.yml -f compose.storagebox.yml --profile podcasts --profile ebooks up -d
```

### Rclone Docker volume plugin (Docker Engine)

Uses the native `rclone` volume driver (still a mount, not a sync). Requires a one-time host setup.

```bash
# 1. Configure credentials on the host
sudo mkdir -p /var/lib/docker-plugins/rclone/config
sudo cp rclone/rclone.conf.example /var/lib/docker-plugins/rclone/config/rclone.conf
sudo $EDITOR /var/lib/docker-plugins/rclone/config/rclone.conf

# 2. Install the plugin
./scripts/install-rclone-plugin-docker.sh

# 3. Set RCLONE_REMOTE in .env
#    Object Storage: RCLONE_REMOTE=hetzner:my-audiobooks
#    Storage Box:    RCLONE_REMOTE=storagebox:

# 4. Start the stack
docker compose -f compose.rclone-plugin.yml up -d

# Modular
docker compose -f compose.rclone-plugin.core.yml -f compose.rclone-plugin.caddy.yml up -d
```

Create `audiobooks`, `podcasts`, and `ebooks` prefixes on the remote before starting (plugin subpath mounts require them).

## Coolify

Use the Coolify compose files on **Coolify 4.5.0 or newer**. Coolify already provides the reverse proxy, so these files omit Caddy, custom networks, fixed `container_name`s, and host port publishes.

Coolify 4.5 keeps long bind options (`propagation`, `create_host_path: false`) and the service settings this stack needs (`privileged`, `devices`, `pid: host`). Leave **Raw Compose** off and assign the domain in the Domains UI. You do not copy the application UUID or run host `mount` / `fuse.conf` commands by hand.

### Deploy

1. In Coolify: **New Resource** → your Git repo → build pack **Docker Compose**.
2. Set **Docker Compose Location** to one of:
   - `/compose.coolify.yml` — Hetzner Object Storage (S3)
   - `/compose.coolify.storagebox.yml` — Hetzner Storage Box (SFTP mount)
3. Leave **Raw Compose Deployment** off.
4. Fill environment variables in the Coolify UI:
   - Object Storage: `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_ENDPOINT`, `S3_BUCKET`, …
   - Storage Box: `STORAGEBOX_HOST`, `STORAGEBOX_USER`, and **`STORAGEBOX_PASS` as the plain password**
   - Or set `STORAGEBOX_KEY_PEM` to an OpenSSH private key (port 23, `\n` between lines) and leave the password empty. The password is not sent when a key is set.
   - For a `media/audiobooks` layout on the box:
     - `STORAGEBOX_PATH=media/`
     - `STORAGEBOX_AUDIOBOOKS_DIR=audiobooks`
     - `STORAGEBOX_PODCASTS_DIR=podcast` (or `podcasts` if that is the folder name)
     - `STORAGEBOX_EBOOKS_DIR=ebooks`
   - Optional: `VFS_CACHE_MAX_SIZE` (default `2G`), `STORAGEBOX_BAN_BACKOFF` (default `15m`), `STORAGEBOX_AUTH_BACKOFF` (default `10m`)
   - Optional override: `HOST_MNT_BASE`. When empty, the mount uses `/data/coolify/applications/<COOLIFY_RESOURCE_UUID>/mnt`.
5. **Domains**: add the hostname on the **audiobookshelf** service. Set the internal port to `80` (`https://books.example.com:80` in the Coolify field). Coolify writes the proxy labels.
6. Deploy.
7. In Audiobookshelf: **Settings → Libraries → Add Library** and set the folder to one of:
   - `/audiobooks`
   - `/podcasts`
   - `/ebooks`

   Type the path if the browser does not show it. Do **not** use a host path like `/data/coolify/...`.

Create those folders on the remote before the first scan. Storage Box: enable **SSH support** and, from outside the Hetzner network, **external reachability** (port `23`).

`fuse-share` runs once per deploy. It makes the Coolify data mount shared, enables `user_allow_other`, installs host `fuse3` and rclone, and adds the fusermount3 AppArmor snippet for `/data/coolify`. **Exited (0)** after `fuse-share: done` is success. If it exits non-zero, the log line starting with `fuse-share: FATAL` is the reason (the data mount could not be made shared, or the host has no `fusermount`). In-container `fusermount` still cannot mount on `/data/coolify` paths, so rclone mounts in the host mount namespace.

Podcast and ebook containers start only after the audiobooks mount is healthy, so a wrong password or a blocked server is one SSH attempt per backoff window.

If uploads in ABS never appear on the Storage Box (or remote files never appear in ABS), ABS is using a **local VPS folder** while rclone FUSE is separate. Confirm rclone logs say `HOST mounting`, then clear leftover files under the app `mnt/` directory and redeploy.

### Coolify notes

| Topic | Detail |
|-------|--------|
| Version | Coolify **4.5.0+** |
| Proxy | Domains UI on **audiobookshelf**, internal port 80. Raw Compose stays off |
| Networks | Coolify compose files define **no** custom networks (required for the proxy) |
| Media mounts | rclone FUSE on the **host** under `/data/coolify/applications/<uuid>/mnt`; ABS binds `./mnt/…` after the audiobooks mount is healthy |
| `HOST_MNT_BASE` | Optional. Default is `/data/coolify/applications/$COOLIFY_RESOURCE_UUID/mnt` |
| `fuse-share` | One-shot. Applies rshared, `user_allow_other`, fuse3, and the AppArmor snippet. `exclude_from_hc` so Exited (0) is not an application failure |
| Upload not on box | ABS wrote to a local VPS shadow. Confirm `HOST mounting` in the rclone log, clear `…/mnt/*`, redeploy |
| rclone unhealthy | Open **rclone** logs. A blocked login waits `STORAGEBOX_BAN_BACKOFF`. A bad password waits `STORAGEBOX_AUTH_BACKOFF` |
| Blocked login | Hetzner (and similar boxes) block the server IP after repeated failures, often for about 15 minutes. Further attempts extend the block. The log tells you to enable SSH support and external reachability, then wait |
| FUSE | `privileged: true`, `/dev/fuse`, `pid: host`. Host rclone is installed by `fuse-share` |
| Healthcheck | Greps host `/proc/1/mounts` for the library path |
| Password | Coolify expects a **plain** `STORAGEBOX_PASS`. If the value is already rclone-obscured, the script tries it once without obscuring it again |
| Key | Optional `STORAGEBOX_KEY_PEM`. When set, the password is not sent |
| Paths | Default remote prefix `media/` + dirs `audiobooks` / `podcast` / `ebooks` (override via env) |
| Disk | Still a mount, not a sync. Lower `VFS_CACHE_MAX_SIZE` on small VPS disks |
| Logs | Check `rclone` logs for `HOST mounting hetzner:media/audiobooks` |

## Podman

The sidecar stack (`compose.yml`) is the recommended path on Podman.

```bash
# Object Storage
podman compose -f compose.yml -f podman/compose.override.yml up -d

# Storage Box
podman compose -f compose.yml -f compose.storagebox.yml -f podman/compose.override.yml up -d
```

### Podman prerequisites

- Install FUSE: `dnf install fuse` or `apt install fuse3`
- Rootless: add `user_allow_other` to `/etc/fuse.conf` if mounts appear empty
- SELinux (Fedora/RHEL): the `podman/compose.override.yml` adds `:Z` volume labels

### Podman + rclone volume plugin (advanced)

Docker's managed plugin (`docker plugin install`) does not work on Podman. Use `rclone serve docker` via systemd instead:

```bash
./scripts/install-rclone-plugin-podman.sh
podman compose -f compose.rclone-plugin.yml up -d
```

## Swapping Caddy for another proxy

Caddy is isolated in `compose.caddy.yml` (or inline in the all-in-one files). To use Traefik, nginx, or another proxy:

1. Start a core file without Caddy:

   ```bash
   docker compose -f compose.core.yml up -d
   # or Storage Box:
   docker compose -f compose.core.yml -f compose.storagebox.yml up -d
   ```

2. Point your proxy at `http://audiobookshelf:80` on the `audiobookshelf_web` network.

### nginx example

```nginx
server {
    listen 443 ssl;
    server_name books.example.com;

    location / {
        proxy_pass http://audiobookshelf:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Traefik example (Docker labels on Audiobookshelf)

Add to `audiobookshelf` in a custom override:

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.abs.rule=Host(`books.example.com`)
  - traefik.http.services.abs.loadbalancer.server.port=80
```

## Configuration

### Environment variables (`.env`)

| Variable | Description |
|----------|-------------|
| `STORAGE_BACKEND` | `objectstorage` (default compose) or `storagebox` (use with `compose.storagebox.yml`) |
| `S3_ACCESS_KEY` | Object Storage access key (sidecar) |
| `S3_SECRET_KEY` | Object Storage secret key (sidecar) |
| `S3_REGION` | Region: `fsn1`, `nbg1`, or `hel1` |
| `S3_ENDPOINT` | e.g. `fsn1.your-objectstorage.com` |
| `S3_BUCKET` | Bucket name |
| `STORAGEBOX_HOST` | e.g. `uXXXXX.your-storagebox.de` |
| `STORAGEBOX_USER` | Storage Box username (or sub-account) |
| `STORAGEBOX_PASS` | Local compose: **rclone-obscured** password (`./scripts/obscure-password.sh`). Coolify: **plain** password |
| `STORAGEBOX_KEY_PEM` | Optional OpenSSH private key (port 23). `\n` for line breaks. When set, the password is not sent |
| `STORAGEBOX_BAN_BACKOFF` | Wait after the storage box blocks this server (default `15m`) |
| `STORAGEBOX_AUTH_BACKOFF` | Wait after a rejected password or key (default `10m`) |
| `STORAGEBOX_PORT` | SSH/SFTP port (default `23`) |
| `STORAGEBOX_PATH` | Prefix on the box with trailing slash (Coolify default `media/`) |
| `STORAGEBOX_AUDIOBOOKS_DIR` | Remote folder name for books (default `audiobooks`) |
| `STORAGEBOX_PODCASTS_DIR` | Remote folder name for podcasts (Coolify default `podcast`) |
| `STORAGEBOX_EBOOKS_DIR` | Remote folder name for ebooks (default `ebooks`) |
| `RCLONE_REMOTE` | Plugin volume remote (`hetzner:bucket` or `storagebox:`) |
| `VFS_CACHE_MODE` | rclone VFS mode (default `full` — best for ABS seeking) |
| `VFS_CACHE_MAX_SIZE` | Max local cache per mount (default `2G`) — keep this small on tiny VPS disks |
| `VFS_CACHE_MAX_AGE` | Evict unused cache entries after this age (default `72h`) |
| `VFS_DIR_CACHE_TIME` | How long directory listings are cached (default `72h`) |
| `DOMAIN` | Caddy site address (`books.example.com` or `:80` for local HTTP) |
| `ACME_EMAIL` | Email for Let's Encrypt (production HTTPS) |
| `ABS_HOST_PORT` | Host port when running without Caddy (default `13378`) |

### Remote layout

| Remote path | Container path | How to enable (sidecar) |
|-------------|----------------|-------------------------|
| `…/audiobooks/` | `/audiobooks` | Always |
| `…/podcasts/` | `/podcasts` | `--profile podcasts` |
| `…/ebooks/` | `/ebooks` | `--profile ebooks` |

Object Storage examples use `s3://<bucket>/audiobooks/`. Storage Box examples use `audiobooks/` at the account root (or under `STORAGEBOX_PATH`).

### Hetzner rclone config (plugin variant)

See [rclone/rclone.conf.example](rclone/rclone.conf.example). Copy to `/var/lib/docker-plugins/rclone/config/rclone.conf` on the host. Uncomment and fill the `[storagebox]` section when using a Storage Box, then set `RCLONE_REMOTE=storagebox:` in `.env`.

## Important notes

- **Mount, not sync** — rclone exposes the remote as a filesystem. The library is not copied onto the VPS.
- **Never put `/config` on remote storage** — the SQLite database must be on local disk ([ABS docs](https://www.audiobookshelf.org/docs/install/docker/)).
- Bound `VFS_CACHE_MAX_SIZE` to what your VPS can spare (per mount: audiobooks, plus podcasts/ebooks if enabled).
- First library scans can be slow while directory listings and the VFS cache warm up.
- Object Storage / Storage Box sidecar credentials come from `.env`. The plugin variant reads remotes from host `rclone.conf`.
- Storage Box: enable **SSH support** in the console; SFTP uses **port 23**. From outside the Hetzner network, also enable **external reachability**. Prefer an SSH key (`STORAGEBOX_KEY_PEM`, or `key_file` in the plugin `rclone.conf`) when you can. A blocked login waits out the block instead of retrying every few seconds.

## Stack comparison

| | Sidecar | Volume plugin |
|---|---------|---------------|
| Host setup | None | Plugin install + `rclone.conf` |
| Docker | Yes | Yes |
| Podman | Yes (recommended) | Advanced (systemd) |
| FUSE in container | Yes | No |
| Object Storage | Default compose | `[hetzner]` + `RCLONE_REMOTE=hetzner:bucket` |
| Storage Box | `compose.storagebox.yml` | `[storagebox]` + `RCLONE_REMOTE=storagebox:` |
