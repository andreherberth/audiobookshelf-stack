#!/bin/sh
# Mount a Storage Box (or any rclone SFTP remote named "hetzner") and back off
# when the server rejects or blocks authentication.
#
# STORAGEBOX_MOUNT_MODE:
#   container  in-container rclone mount (local compose.storagebox.yml)
#   host       host-namespace mount via nsenter (Coolify)
#
# STORAGEBOX_PASS_KIND:
#   plain      Coolify: STORAGEBOX_PASS is the plain password (obscured here)
#   obscured   local compose: STORAGEBOX_PASS is already rclone-obscured
#
# When STORAGEBOX_KEY_PEM is set (OpenSSH private key), the password is not sent.
#
# Source this file with STORAGEBOX_MOUNT_TEST=1 to use the classifier in tests.

set -u

classify_storagebox_error() {
  file=$1
  if [ ! -s "$file" ]; then
    echo other
    return 0
  fi
  if grep -Eiq 'kex_exchange_identification|connection reset by peer|connection closed by remote host|connection refused|too many authentication failures|ip has been blocked|temporarily blocked|host is blocked|authentication is blocked|[[:space:]]blocked([[:space:]]|$)|^blocked([[:space:]]|$)' "$file"; then
    echo blocked
    return 0
  fi
  if grep -Eiq 'too many connections|too many sessions|connection limit|maximum number of connections|sorry, too many' "$file"; then
    echo sessions
    return 0
  fi
  if grep -Eiq 'unable to authenticate|authentication failed|no supported authentication methods|no supported methods|handshake failed|permission denied, please try again|all configured authentication methods failed' "$file"; then
    echo auth
    return 0
  fi
  if grep -Eiq 'directory not found|object not found' "$file"; then
    echo missing
    return 0
  fi
  echo other
}

storagebox_backoff_for() {
  case "$1" in
    blocked) printf '%s\n' "${STORAGEBOX_BAN_BACKOFF:-15m}" ;;
    auth) printf '%s\n' "${STORAGEBOX_AUTH_BACKOFF:-10m}" ;;
    sessions) printf '%s\n' "${STORAGEBOX_SESSION_BACKOFF:-2m}" ;;
    *) printf '%s\n' "${STORAGEBOX_RETRY_DELAY:-20s}" ;;
  esac
}

storagebox_failure_message() {
  class=$1
  remote=$2
  case "$class" in
    blocked)
      echo "rclone: the storage box has blocked this server. On Hetzner enable SSH support and external reachability, then wait for the block to expire (often about 15 minutes). Further login attempts extend the block. Sleeping ${STORAGEBOX_BAN_BACKOFF:-15m}."
      ;;
    auth)
      echo "rclone: storage box rejected authentication. On Coolify, STORAGEBOX_PASS must be the plain password. On the local compose overlay, STORAGEBOX_PASS must be the rclone-obscured password. Or set STORAGEBOX_KEY_PEM (OpenSSH private key). Sleeping ${STORAGEBOX_AUTH_BACKOFF:-10m}."
      ;;
    missing)
      echo "rclone: remote folder was not found: ${remote}. Check STORAGEBOX_PATH and the library folder name. Retrying in ${STORAGEBOX_RETRY_DELAY:-20s}."
      ;;
    sessions)
      echo "rclone: storage box connection limit reached (Hetzner allows a small number of simultaneous sessions). Sleeping ${STORAGEBOX_SESSION_BACKOFF:-2m}."
      ;;
    *)
      echo "rclone: mount probe failed. Retrying in ${STORAGEBOX_RETRY_DELAY:-20s}."
      ;;
  esac
}

password_looks_obscured() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/_=-]{24,}$'
}

write_storagebox_key() {
  dest=$1
  plain=/tmp/storagebox-key.plain
  printf '%s' "$STORAGEBOX_KEY_PEM" > "$plain"
  if [ "$(wc -l < "$plain")" -eq 0 ] && grep -q '\\n' "$plain"; then
    sed 's/\\n/\n/g' "$plain" > "${plain}.expanded"
    mv "${plain}.expanded" "$plain"
  fi
  if [ "$mode" = "host" ]; then
    nsenter -t 1 -m -- tee "$dest" < "$plain" >/dev/null
    nsenter -t 1 -m -- chmod 600 "$dest"
  else
    cat "$plain" > "$dest"
    chmod 600 "$dest"
  fi
  rm -f "$plain"
  export RCLONE_CONFIG_HETZNER_KEY_FILE="$dest"
  unset RCLONE_CONFIG_HETZNER_PASS
  echo "rclone: authenticating with STORAGEBOX_KEY_PEM"
}

apply_storagebox_password() {
  if [ -n "${STORAGEBOX_KEY_PEM:-}" ]; then
    return 0
  fi

  if [ -z "${STORAGEBOX_PASS:-}" ] && [ -z "${RCLONE_CONFIG_HETZNER_PASS:-}" ]; then
    echo "rclone: FATAL set STORAGEBOX_PASS or STORAGEBOX_KEY_PEM"
    return 1
  fi

  case "${STORAGEBOX_PASS_KIND:-plain}" in
    obscured)
      if [ -n "${STORAGEBOX_PASS:-}" ]; then
        export RCLONE_CONFIG_HETZNER_PASS="$STORAGEBOX_PASS"
      fi
      ;;
    plain)
      if [ "${STORAGEBOX_TRIED_RAW_PASS:-}" = "1" ]; then
        export RCLONE_CONFIG_HETZNER_PASS="$STORAGEBOX_PASS"
        echo "rclone: using STORAGEBOX_PASS as an already-obscured password"
      else
        obscured=$(rclone obscure "$STORAGEBOX_PASS") || {
          echo "rclone: FATAL could not obscure STORAGEBOX_PASS"
          return 1
        }
        export RCLONE_CONFIG_HETZNER_PASS="$obscured"
      fi
      ;;
    *)
      echo "rclone: FATAL unknown STORAGEBOX_PASS_KIND=${STORAGEBOX_PASS_KIND}"
      return 1
      ;;
  esac
}

# Returns 0 when the next attempt should use the raw password once.
storagebox_should_try_raw_password() {
  [ "${STORAGEBOX_PASS_KIND:-plain}" = "plain" ] || return 1
  [ "${STORAGEBOX_TRIED_RAW_PASS:-}" = "1" ] && return 1
  [ -n "${STORAGEBOX_KEY_PEM:-}" ] && return 1
  [ -n "${STORAGEBOX_PASS:-}" ] || return 1
  password_looks_obscured "$STORAGEBOX_PASS"
}

resolve_host_mnt_base() {
  if [ -n "${HOST_MNT_BASE:-}" ]; then
    return 0
  fi
  if [ -z "${COOLIFY_RESOURCE_UUID:-}" ]; then
    echo "rclone: FATAL HOST_MNT_BASE is empty and COOLIFY_RESOURCE_UUID is unset. Deploy with Coolify 4.5+ or set HOST_MNT_BASE."
    return 1
  fi
  HOST_MNT_BASE="/data/coolify/applications/${COOLIFY_RESOURCE_UUID}/mnt"
  export HOST_MNT_BASE
}

report_failure() {
  errfile=$1
  class=$(classify_storagebox_error "$errfile")
  if [ "$class" = "auth" ] && storagebox_should_try_raw_password; then
    STORAGEBOX_TRIED_RAW_PASS=1
    export STORAGEBOX_TRIED_RAW_PASS
    echo "rclone: STORAGEBOX_PASS looks rclone-obscured; retrying once without obscuring it"
    apply_storagebox_password || true
    echo "rclone: server said:"
    cat "$errfile"
    sleep "${STORAGEBOX_RETRY_DELAY:-20s}"
    return 0
  fi
  storagebox_failure_message "$class" "$remote"
  echo "rclone: server said:"
  cat "$errfile"
  sleep "$(storagebox_backoff_for "$class")"
}

run_probe() {
  probe_err=/tmp/storagebox-probe.err
  : > "$probe_err"
  if rclone lsf "$remote" --max-depth 1 >/tmp/storagebox-probe.out 2>"$probe_err"; then
    return 0
  fi
  report_failure "$probe_err"
  return 1
}

mount_container() {
  echo "user_allow_other" > /etc/fuse.conf
  mount_log=/tmp/storagebox-mount.log
  : > "$mount_log"
  echo "rclone: mounting $remote -> $RCLONE_MOUNT_PATH"
  set +e
  set -o pipefail
  rclone mount "$remote" "$RCLONE_MOUNT_PATH" \
    --allow-other \
    --vfs-cache-mode "$VFS_CACHE_MODE" \
    --vfs-cache-max-size "$VFS_CACHE_MAX_SIZE" \
    --vfs-cache-max-age "$VFS_CACHE_MAX_AGE" \
    --cache-dir /cache \
    --dir-cache-time "$VFS_DIR_CACHE_TIME" \
    --checkers "$RCLONE_CHECKERS" \
    --log-level INFO 2>&1 | tee "$mount_log"
  status=$?
  set +o pipefail
  echo "rclone: mount exited status=$status for $RCLONE_MOUNT_PATH"
  if [ "$status" -eq 0 ]; then
    echo "rclone: mount ended; retrying in ${STORAGEBOX_RETRY_DELAY:-20s}"
    sleep "${STORAGEBOX_RETRY_DELAY:-20s}"
    return 0
  fi
  report_failure "$mount_log"
}

mount_host() {
  host_rclone=$1
  host_path=$2
  cache_dir=$3
  fusermount_prog=$(nsenter -t 1 -m -- sh -c 'command -v fusermount3 2>/dev/null || command -v fusermount 2>/dev/null || true')
  if [ -z "$fusermount_prog" ]; then
    echo "rclone: FATAL host fusermount missing. fuse-share should install fuse3; see that service log."
    sleep 60
    return 1
  fi
  export FUSERMOUNT_PROG="$fusermount_prog"
  echo "rclone: FUSERMOUNT_PROG=$FUSERMOUNT_PROG"

  nsenter -t 1 -m -- mkdir -p "$host_path" "$cache_dir"

  if nsenter -t 1 -m -- findmnt -M "$host_path" >/dev/null 2>&1; then
    echo "rclone: unmounting stale FUSE at $host_path"
    nsenter -t 1 -m -- "$fusermount_prog" -uz "$host_path" 2>/dev/null \
      || nsenter -t 1 -m -- umount -l "$host_path" 2>/dev/null \
      || true
    sleep 1
  elif [ -n "$(nsenter -t 1 -m -- ls -A "$host_path" 2>/dev/null || true)" ]; then
    echo "rclone: clearing local shadow files under $host_path"
    nsenter -t 1 -m -- find "$host_path" -mindepth 1 -delete 2>/dev/null || true
  fi

  mount_log=/tmp/storagebox-mount.log
  : > "$mount_log"
  echo "rclone: HOST mounting $remote -> $host_path"
  set +e
  set -o pipefail
  nsenter -t 1 -m -- "$host_rclone" mount "$remote" "$host_path" \
    --allow-other \
    --allow-non-empty \
    --vfs-cache-mode "$VFS_CACHE_MODE" \
    --vfs-cache-max-size "$VFS_CACHE_MAX_SIZE" \
    --vfs-cache-max-age "$VFS_CACHE_MAX_AGE" \
    --cache-dir "$cache_dir" \
    --dir-cache-time "$VFS_DIR_CACHE_TIME" \
    --checkers "$RCLONE_CHECKERS" \
    --log-level INFO 2>&1 | tee "$mount_log"
  status=$?
  set +o pipefail
  echo "rclone: mount exited status=$status for $host_path"
  if [ "$status" -eq 0 ]; then
    echo "rclone: mount ended; retrying in ${STORAGEBOX_RETRY_DELAY:-20s}"
    sleep "${STORAGEBOX_RETRY_DELAY:-20s}"
    return 0
  fi
  report_failure "$mount_log"
}

storagebox_main() {
  VFS_CACHE_MODE="${VFS_CACHE_MODE:-full}"
  VFS_CACHE_MAX_SIZE="${VFS_CACHE_MAX_SIZE:-2G}"
  VFS_CACHE_MAX_AGE="${VFS_CACHE_MAX_AGE:-72h}"
  VFS_DIR_CACHE_TIME="${VFS_DIR_CACHE_TIME:-72h}"
  RCLONE_CHECKERS="${RCLONE_CHECKERS:-2}"
  STORAGEBOX_PATH="${STORAGEBOX_PATH:-}"
  remote="hetzner:${STORAGEBOX_PATH}${RCLONE_REMOTE_SUBDIR:?set RCLONE_REMOTE_SUBDIR}"
  mode="${STORAGEBOX_MOUNT_MODE:-container}"

  echo "rclone: start mode=$mode subdir=${RCLONE_REMOTE_SUBDIR} script=storagebox-mount"

  case "$mode" in
    container)
      if [ -n "${STORAGEBOX_KEY_PEM:-}" ]; then
        write_storagebox_key /tmp/storagebox-key.pem
      elif ! apply_storagebox_password; then
        sleep "${STORAGEBOX_AUTH_BACKOFF:-10m}"
        exit 1
      fi
      if [ ! -e /dev/fuse ]; then
        echo "rclone: FATAL /dev/fuse missing. The compose service needs devices: /dev/fuse and cap_add: SYS_ADMIN."
        sleep 60
        exit 1
      fi
      RCLONE_MOUNT_PATH="${RCLONE_MOUNT_PATH:?set RCLONE_MOUNT_PATH}"
      while true; do
        if run_probe; then
          rclone mkdir "$remote" 2>/dev/null || true
          mount_container
        fi
      done
      ;;
    host)
      if [ ! -e /dev/fuse ]; then
        echo "rclone: FATAL /dev/fuse missing. On Coolify 4.5+ leave Raw Compose off; this file sets privileged and /dev/fuse."
        sleep 60
        exit 1
      fi
      if ! resolve_host_mnt_base; then
        sleep 60
        exit 1
      fi
      host_path="${HOST_MNT_BASE}/${STORAGEBOX_PATH}${RCLONE_HOST_SUBDIR:?set RCLONE_HOST_SUBDIR}"
      app_dir=$(dirname "$HOST_MNT_BASE")
      cache_dir="${app_dir}/rclone-cache/${RCLONE_HOST_SUBDIR}"
      bin_dir="${app_dir}/bin"
      host_rclone="${bin_dir}/rclone"
      if [ -n "${STORAGEBOX_KEY_PEM:-}" ]; then
        write_storagebox_key "${app_dir}/storagebox-key.pem"
      elif ! apply_storagebox_password; then
        sleep "${STORAGEBOX_AUTH_BACKOFF:-10m}"
        exit 1
      fi
      echo "rclone: remote=$remote"
      echo "rclone: host_path=$host_path"
      echo "rclone: host_rclone=$host_rclone"
      while true; do
        if ! nsenter -t 1 -m -- test -x "$host_rclone"; then
          echo "rclone: FATAL $host_rclone missing. Check fuse-share logs."
          sleep 60
          continue
        fi
        if run_probe; then
          rclone mkdir "$remote" 2>/dev/null || true
          mount_host "$host_rclone" "$host_path" "$cache_dir" || true
        fi
      done
      ;;
    *)
      echo "rclone: FATAL unknown STORAGEBOX_MOUNT_MODE=$mode"
      exit 1
      ;;
  esac
}

if [ "${STORAGEBOX_MOUNT_TEST:-}" != "1" ]; then
  storagebox_main "$@"
fi
