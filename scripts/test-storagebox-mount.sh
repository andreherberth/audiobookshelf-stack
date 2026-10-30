#!/bin/sh
# Classifier and compose checks for the Storage Box mount.
# Coolify's exclude_from_hc key is not in the Compose schema, so that one line
# is removed before `docker compose config`. The committed file keeps it.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

sh -n scripts/storagebox-mount.sh

tmp=$(mktemp)
fail() {
  echo "FAIL: $1" >&2
  exit 1
}

STORAGEBOX_MOUNT_TEST=1
# shellcheck disable=SC1091
. ./scripts/storagebox-mount.sh

check() {
  name=$1
  text=$2
  want=$3
  phrase=$4
  delay=$5
  printf '%s\n' "$text" > "$tmp"
  got=$(classify_storagebox_error "$tmp")
  [ "$got" = "$want" ] || fail "$name class got=$got want=$want"
  msg=$(storagebox_failure_message "$got" "hetzner:media/audiobooks")
  printf '%s' "$msg" | grep -q "$phrase" || fail "$name phrase missing: $msg"
  gotd=$(storagebox_backoff_for "$got")
  [ "$gotd" = "$delay" ] || fail "$name delay got=$gotd want=$delay"
  echo "ok $name"
}

check ban "kex_exchange_identification: Connection reset by peer" blocked "blocked this server" 15m
check auth "ssh: handshake failed: ssh: unable to authenticate, attempted methods [none password], no supported methods remain" auth "plain password" 10m
check miss "Failed to lsf with 2 errors: last error was: directory not found" missing "remote folder was not found" 20s
check sess "sorry, too many connections" sessions "connection limit" 2m
check other "fusermount3: mount failed: Permission denied" other "mount probe failed" 20s

password_looks_obscured "abcdefghijklmnopqrstuvwxyz12" || fail "obscured password not detected"
if password_looks_obscured "short"; then
  fail "short password looked obscured"
fi
if password_looks_obscured "my plain password"; then
  fail "plain password looked obscured"
fi

STORAGEBOX_PASS_KIND=plain
STORAGEBOX_PASS=abcdefghijklmnopqrstuvwxyz12
STORAGEBOX_TRIED_RAW_PASS=
storagebox_should_try_raw_password || fail "expected one raw-password retry"
STORAGEBOX_TRIED_RAW_PASS=1
if storagebox_should_try_raw_password; then
  fail "raw-password retry ran twice"
fi
echo "ok password retry"

export STORAGEBOX_HOST=u123.your-storagebox.de
export STORAGEBOX_USER=u123
export STORAGEBOX_PASS=secret
export COOLIFY_RESOURCE_UUID=abc123uuid
export S3_ACCESS_KEY=key
export S3_SECRET_KEY=secret
export S3_ENDPOINT=fsn1.your-objectstorage.com
export S3_BUCKET=my-audiobooks
export S3_REGION=fsn1
export TZ=Europe/Berlin

docker compose -f compose.coolify.yml config >/dev/null
echo "ok compose.coolify.yml"

grep -q 'exclude_from_hc: true' compose.coolify.storagebox.yml || fail "missing exclude_from_hc"
filtered=$(mktemp)
sed '/exclude_from_hc: true/d' compose.coolify.storagebox.yml > "$filtered"
docker compose -f "$filtered" config --format json > /tmp/storagebox-coolify.json
python3 - << 'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path("/tmp/storagebox-coolify.json").read_text())
content = data["configs"]["storagebox-mount"]["content"].replace("$$", "$")
script = pathlib.Path("scripts/storagebox-mount.sh").read_text()
if content != script:
    sys.stderr.write("embedded storagebox-mount.sh does not match scripts/storagebox-mount.sh\n")
    sys.exit(1)
for name in ("rclone-podcasts", "rclone-ebooks"):
    deps = data["services"][name]["depends_on"]
    if "rclone" not in deps or deps["rclone"].get("condition") != "service_healthy":
        sys.stderr.write(f"{name} must wait for the audiobooks mount\n")
        sys.exit(1)
labels = data["services"]["audiobookshelf"].get("labels") or {}
if labels:
    sys.stderr.write(f"audiobookshelf should not set proxy labels: {labels}\n")
    sys.exit(1)
if data["services"]["rclone"]["environment"].get("COOLIFY_RESOURCE_UUID") != "abc123uuid":
    sys.stderr.write("COOLIFY_RESOURCE_UUID was not passed through\n")
    sys.exit(1)
cmd = data["services"]["fuse-share"]["command"]
text = cmd if isinstance(cmd, str) else "\n".join(cmd)
text = text.replace("$$", "$")
path = pathlib.Path("/tmp/fuse-share.sh")
path.write_text(text)
print("ok embedded script and service graph")
PY
sh -n /tmp/fuse-share.sh
echo "ok fuse-share syntax"

docker compose -f compose.yml -f compose.storagebox.yml --profile podcasts --profile ebooks config >/dev/null
docker compose -f compose.core.yml -f compose.storagebox.yml --profile podcasts --profile ebooks config >/dev/null
echo "ok local storagebox overlays"

rm -f "$tmp" "$filtered"
echo "all checks passed"
