#!/usr/bin/env bash
#
# wp-migrate-local.sh
#
# Local-only WordPress migration wizard:

set -euo pipefail
set -x  # Debugging enabled

MIGRATE_ROOT="/root/wp-migrate"

log() { echo "[+] $*"; }
warn() { echo "[-] $*"; }
err() { echo "[!] $*" >&2; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "Must be run as root."
    exit 1
  fi
}

check_tools() {
  local missing=0
  for c in mysqldump mysql tar gzip rsync stat zcat; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "Required command '$c' not found. Install it (apt-get)."
      missing=1
    fi
  done
  if (( missing != 0 )); then
    exit 1
  fi
}

discover_wp_paths() {
  mapfile -t WP_PATHS < <(
    find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null \
      | sed 's#/wp-config.php$##' | sort
  )
}

do_old_server_backup() {
  discover_wp_paths
  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found under /home."
    return
  fi

  log "Detected WordPress installations:"
  local i=1
  for wp in "${WP_PATHS[@]}"; do
    local db domain
    db=$(grep -E "define\\(\\s*'DB_NAME'" "$wp/wp-config.php" 2>/dev/null | awk -F"'" '{print $4}')
    domain="$(basename "$(dirname "$wp")")"
    echo "  [$i] $domain (DB: ${db:-UNKNOWN}, Path: $wp)"
    ((i++))
  done

  read -rp "Backup which sites? (e.g. 1 2 5, or A for all): " selection
  declare -a SELECTED_WP_PATHS=()
  if [[ "$selection" =~ ^[Aa]$ ]]; then
    SELECTED_WP_PATHS=("${WP_PATHS[@]}")
  else
    for token in $selection; do
      if ! [[ "$token" =~ ^[0-9]+$ ]]; then
        warn "Ignoring invalid token '$token' (not a number)."
        continue
      fi
      if (( token < 1 || token > ${#WP_PATHS[@]} )); then
        warn "Ignoring out-of-range index '$token'."
        continue
      fi
      SELECTED_WP_PATHS+=("${WP_PATHS[token-1]}")
    done
    if [[ ${#SELECTED_WP_PATHS[@]} -eq 0 ]]; then
      err "No valid sites selected; nothing to back up."
      return
    fi
  fi

  log "You selected ${#SELECTED_WP_PATHS[@]} site(s) to back up:"
  for wp in "${SELECTED_WP_PATHS[@]}"; do
    local domain
    domain="$(basename "$(dirname "$wp")")"
    echo "  - $domain ($wp)"
  done

  if [[ "${1-}" != "--non-interactive" ]]; then
    read -rp "Create LOCAL migration backups for these site(s) under ${MIGRATE_ROOT}? (y/N): " ok
    [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }
  fi

  local TS
  TS="$(date +%Y%m%d-%H%M%S)"

  for wp in "${SELECTED_WP_PATHS[@]}"; do
    local db domain domain_dir
    db=$(grep -E "define\\(\\s*'DB_NAME'" "$wp/wp-config.php" 2>/dev/null | awk -F"'" '{print $4}')
    domain="$(basename "$(dirname "$wp")")"
    if [[ -z "$db" ]]; then
      warn "Skipping $domain — cannot parse DB_NAME."
      continue
    fi

    domain_dir="${MIGRATE_ROOT}/${domain}"
    mkdir -p "$domain_dir"

    local DB_FILE="${domain_dir}/${domain}-db-${TS}-migrate.sql.gz"
    local FILES_FILE="${domain_dir}/${domain}-files-${TS}-migrate.tar.gz"

    log "Backing up $domain for migration..."
    if [[ -f /root/.my.cnf ]]; then
      if ! mysqldump "$db" | gzip > "$DB_FILE"; then
        err "DB backup failed for $db"
        rm -f "$DB_FILE"
        continue
      fi
    else
      if ! mysqldump -u root -p "$db" | gzip > "$DB_FILE"; then
        err "DB backup failed for $db"
        rm -f "$DB_FILE"
        continue
      fi
    fi

    log "DB backup: $DB_FILE"
    if ! tar -czf "$FILES_FILE" -C "$(dirname "$wp")" "$(basename "$wp")"; then
      err "Files backup failed for $domain"
      rm -f "$FILES_FILE"
      continue
    fi

    log "Files backup: $FILES_FILE"
  done

  log "Local migration backups created under: ${MIGRATE_ROOT}"

  echo "Next step (for migration):"
  echo "  - Copy ${MIGRATE_ROOT} to the new server (e.g. rsync or scp)"

  echo
  read -rp "Do you want to PUSH ${MIGRATE_ROOT} to a remote NEW server now via rsync? (y/N): " push
  if [[ "$push" =~ ^[Yy]$ ]]; then
    local NEW_IP SSH_PORT
    echo
    read -rp "Enter NEW server IP (e.g. 65.109.33.94): " NEW_IP
    if [[ -z "$NEW_IP" ]]; then
      warn "No IP entered. Skipping rsync push."
      return
    fi

    read -rp "Enter SSH port for the new server (default: 22): " SSH_PORT
    SSH_PORT="${SSH_PORT:-22}"

    local REMOTE_DEST="root@${NEW_IP}"
    local REMOTE_DIR="/root/wp-migrate"

    log "Pushing ${MIGRATE_ROOT}/  →  ${REMOTE_DEST}:${REMOTE_DIR}/"
    if ! rsync -avz -e "ssh -p $SSH_PORT" "${MIGRATE_ROOT}/" "${REMOTE_DEST}:${REMOTE_DIR}/"; then
      err "rsync push failed."
      return
    fi

    log "rsync push completed."
  fi
}

main() {
  require_root
  check_tools

  case "${1-}" in
    --backup-only)
      do_old_server_backup --non-interactive
      ;;
    "")
      log "Select migration mode:"
      echo "1) Old Server"
      echo "2) New Server"
      read -rp "Choose [1-2]: " mode
      case "$mode" in
        1) do_old_server_backup ;;
        2) do_new_server_restore ;;
        *) err "Invalid choice." ;;
      esac
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
}

main "$@"
