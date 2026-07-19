# Audiobookshelf + Hetzner S3 + Caddy

A Docker/Podman Compose stack for deploying [Audiobookshelf](https://www.audiobookshelf.org/) with media stored on Hetzner Object Storage (or any S3-compatible backend) and Caddy as the default reverse proxy.

Audiobookshelf does not support S3 natively. This stack mounts your bucket as a local filesystem via [rclone](https://rclone.org/). The SQLite database (`/config`) and metadata cache always stay on local disk.

## Quick start

1. Create a [Hetzner Object Storage](https://docs.hetzner.com/storage/object-storage/) bucket and S3 credentials.
2. Copy and edit the environment file:

   ```bash
   cp .env.example .env
   # Set S3_ACCESS_KEY, S3_SECRET_KEY, S3_REGION, S3_ENDPOINT, S3_BUCKET
   ```

3. Create local data directories:

   ```bash
   mkdir -p data/config data/metadata
   ```

4. Start the stack:

   ```bash
   docker compose up -d
   ```

5. Open your instance (e.g. `https://books.example.com` or `http://localhost` if `DOMAIN=:80`).
6. In Audiobookshelf, add a library pointing at `/audiobooks`.

Upload media to your bucket prefix with `rclone copy`, the Hetzner Console, or any S3 client:

```bash
rclone copy ./my-book/ hetzner:my-audiobooks/audiobooks/my-book/
```

## Compose files

| File | Description |
|------|-------------|
| `compose.yml` | **Default** — rclone sidecar + Audiobookshelf + Caddy |
| `compose.core.yml` | Sidecar stack without proxy (exposes port `13378`) |
| `compose.caddy.yml` | Caddy overlay — pairs with any core file |
| `compose.rclone-plugin.yml` | Plugin stack + Caddy (all-in-one) |
| `compose.rclone-plugin.core.yml` | Plugin stack without proxy |
| `compose.rclone-plugin.caddy.yml` | Caddy overlay for plugin core |

### Sidecar (recommended for Docker and Podman)

Uses an rclone container with FUSE. No host plugin install required.

```bash
# All-in-one with Caddy
docker compose up -d

# Modular — no proxy
docker compose -f compose.core.yml up -d

# Modular — with Caddy
docker compose -f compose.core.yml -f compose.caddy.yml up -d

# Optional podcast library on S3
docker compose --profile podcasts up -d
```

### Rclone Docker volume plugin (Docker Engine)

Uses the native `rclone` volume driver. Requires a one-time host setup.

```bash
# 1. Configure credentials on the host
sudo mkdir -p /var/lib/docker-plugins/rclone/config
sudo cp rclone/rclone.conf.example /var/lib/docker-plugins/rclone/config/rclone.conf
sudo $EDITOR /var/lib/docker-plugins/rclone/config/rclone.conf

# 2. Install the plugin
./scripts/install-rclone-plugin-docker.sh

# 3. Start the stack
docker compose -f compose.rclone-plugin.yml up -d

# Modular
docker compose -f compose.rclone-plugin.core.yml -f compose.rclone-plugin.caddy.yml up -d
```

## Podman

The sidecar stack (`compose.yml`) is the recommended path on Podman.

```bash
podman compose -f compose.yml -f podman/compose.override.yml up -d
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
| `S3_ACCESS_KEY` | Hetzner S3 access key (sidecar stack) |
| `S3_SECRET_KEY` | Hetzner S3 secret key (sidecar stack) |
| `S3_REGION` | Region: `fsn1`, `nbg1`, or `hel1` |
| `S3_ENDPOINT` | e.g. `fsn1.your-objectstorage.com` |
| `S3_BUCKET` | Bucket name |
| `DOMAIN` | Caddy site address (`books.example.com` or `:80` for local HTTP) |
| `ACME_EMAIL` | Email for Let's Encrypt (production HTTPS) |
| `ABS_HOST_PORT` | Host port when running without Caddy (default `13378`) |

### Bucket layout

| S3 path | Container path |
|---------|----------------|
| `s3://<bucket>/audiobooks/` | `/audiobooks` |
| `s3://<bucket>/podcasts/` | `/podcasts` |

### Hetzner rclone config (plugin variant)

See [rclone/rclone.conf.example](rclone/rclone.conf.example). Copy to `/var/lib/docker-plugins/rclone/config/rclone.conf` on the host.

## Important notes

- **Never put `/config` on S3** — the SQLite database must be on local disk ([ABS docs](https://www.audiobookshelf.org/docs/install/docker/)).
- First library scans over S3 can be slow while the rclone VFS cache warms up.
- The sidecar variant reads S3 credentials from `.env`. The plugin variant reads them from host `rclone.conf`.

## Stack comparison

| | Sidecar | Volume plugin |
|---|---------|---------------|
| Host setup | None | Plugin install + `rclone.conf` |
| Docker | Yes | Yes |
| Podman | Yes (recommended) | Advanced (systemd) |
| FUSE in container | Yes | No |
