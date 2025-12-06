#!/usr/bin/env bash
#
# wp-migrate-local.sh
#
# Local-only WordPress migration wizard:
#
# 1) Old Server:
#    - Create local backups in /root/wp-migrate/<domain>/
#    - DB + files, no Dropbox involved
#    - Optional rsync push of /root/wp-migrate to a remote NEW server
#
# 2) New Server:
#    - Restore from local backups in /root/wp-migrate/<domain>/
#
# --backup-only:
#    - Old server backup mode: let user select site(s), create local backups,
#      then offer rsync push to new server (ask only for NEW server IP).
#

set -euo pipefail

MIGRATE_ROOT="/root/wp-migrate"

log()  { echo "[+] $*"; }
warn() { echo "[-] $*"; }
err()  { echo "[!] $*" >&2; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "Must be run as root."
    exit 1
  fi
}

check_tools() {
  local missing=0
  # zcat added because we use it in restore
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

  echo
  log "Detected WordPress installations:"
  local i=1
  for wp in "${WP_PATHS[@]}"; do
    local db domain
    db=$(grep -E "define\\(\\s*'DB_NAME'" "$wp/wp-config.php" 2>/dev/null | awk -F"'" '{print $4}')
    domain="$(basename "$(dirname "$wp")")"
    echo "  [$i] $domain (DB: ${db:-UNKNOWN}, Path: $wp)"
    ((i++))
  done

  echo
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

  echo
  log "You selected ${#SELECTED_WP_PATHS[@]} site(s) to back up:"
  for wp in "${SELECTED_WP_PATHS[@]}"; do
    local domain
    domain="$(basename "$(dirname "$wp")")"
    echo "  - $domain ($wp)"
  done

  # Only ask this confirmation if not invoked as --non-interactive
  if [[ "${1-}" != "--non-interactive" ]]; then
    echo
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

    echo
    log "Backing up $domain for migration..."
    log "  DB: $db"
    log "  Path: $wp"

    # DB backup
    if [[ -f /root/.my.cnf ]]; then
      if ! mysqldump "$db" | gzip > "$DB_FILE"; then
        err "DB backup failed for $db"
        rm -f "$DB_FILE"
        continue
      fi
    else
      warn "/root/.my.cnf not found. You may be prompted..."
      if ! mysqldump -u root -p "$db" | gzip > "$DB_FILE"; then
        err "DB backup failed for $db"
        rm -f "$DB_FILE"
        continue
      fi
    fi
    log "  DB backup: $DB_FILE"

    # Files backup
    local parent base
    parent="$(dirname "$wp")"
    base="$(basename "$wp")"
    if ! tar -czf "$FILES_FILE" -C "$parent" "$base"; then
      err "Files backup failed for $domain"
      rm -f "$FILES_FILE"
      continue
    fi
    log "  Files backup: $FILES_FILE"
  done

  echo
  log "Local migration backups created under: ${MIGRATE_ROOT}"
  echo "Next step (for migration):"
  echo "  - Copy ${MIGRATE_ROOT} to the new server (e.g. rsync or scp)"

   # NEW: offer to push /root/wp-migrate to a remote server via rsync (IP and port)
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
    SSH_PORT="${SSH_PORT:-22}"  # Set default to 22 if no input provided

    local REMOTE_DEST="root@${NEW_IP}"
    local REMOTE_DIR="/root/wp-migrate"

    echo
    log "Pushing ${MIGRATE_ROOT}/  →  ${REMOTE_DEST}:${REMOTE_DIR}/"
    log "You will be prompted for the SSH password for root@${NEW_IP} (unless keys are set)."

    # Update rsync command to use the custom SSH port
    if ! rsync -avz -e "ssh -p $SSH_PORT" "${MIGRATE_ROOT}/" "${REMOTE_DEST}:${REMOTE_DIR}/"; then
      err "rsync push failed. Please check SSH connectivity and rerun the push manually."
      return
    fi

    log "rsync push completed."
  fi

do_new_server_restore() {
  if [[ ! -d "$MIGRATE_ROOT" ]]; then
    err "Migration backup directory not found: ${MIGRATE_ROOT}"
    echo "Please copy it from the old server first."
    return
  fi

  mapfile -t DOMAINS < <(find "$MIGRATE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort)
  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    warn "No domain folders found under ${MIGRATE_ROOT}."
    return
  fi

  echo
  echo "Available migration backups:"
  local i=1
  for d in "${DOMAINS[@]}"; do
    echo "  [$i] $d"
    ((i++))
  done
  echo

  local sel
  while :; do
    read -rp "Select a site to restore [1-${#DOMAINS[@]}]: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] || { warn "Enter a number."; continue; }
    (( sel >= 1 && sel <= ${#DOMAINS[@]} )) || { warn "Out of range."; continue; }
    break
  done

  local domain="${DOMAINS[sel-1]}"
  local domain_dir="${MIGRATE_ROOT}/${domain}"

  local latest_db latest_files
  latest_db="$(ls -1t "${domain_dir}/${domain}-db-"*"-migrate.sql.gz" 2>/dev/null | head -n1 || true)"
  latest_files="$(ls -1t "${domain_dir}/${domain}-files-"*"-migrate.tar.gz" 2>/dev/null | head -n1 || true)"

  if [[ -z "$latest_db" || -z "$latest_files" ]]; then
    err "Could not find DB and files backups for ${domain} in ${domain_dir}."
    return
  fi

  echo
  log "Using DB backup   : $latest_db"
  log "Using FILES backup: $latest_files"

  local TMP_DIR
  TMP_DIR="$(mktemp -d "/tmp/wp-migrate-${domain}-XXXXXX")"

  if ! tar -xzf "$latest_files" -C "$TMP_DIR"; then
    err "Failed to extract files archive."
    rm -rf "$TMP_DIR"
    return
  fi

  local config
  config="$(find "$TMP_DIR" -maxdepth 4 -name 'wp-config.php' | head -n1 || true)"
  if [[ -z "$config" ]]; then
    err "Could not find wp-config.php in extracted files."
    rm -rf "$TMP_DIR"
    return
  fi

  local DB_NAME DB_USER DB_PASS
  DB_NAME="$(grep -E "define\\(\\s*'DB_NAME'" "$config" | awk -F"'" '{print $4}')"
  DB_USER="$(grep -E "define\\(\\s*'DB_USER'" "$config" | awk -F"'" '{print $4}')"
  DB_PASS="$(grep -E "define\\(\\s*'DB_PASSWORD'" "$config" | awk -F"'" '{print $4}')"

  if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
    err "Failed to parse DB credentials from wp-config.php."
    rm -rf "$TMP_DIR"
    return
  fi

  echo
  log "Parsed DB credentials:"
  echo "  DB_NAME: $DB_NAME"
  echo "  DB_USER: $DB_USER"
  echo "  DB_PASS: (hidden)"

  echo
  read -rp "Proceed with RESTORE for ${domain} on THIS server? (y/N): " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; rm -rf "$TMP_DIR"; return; }

  mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" || true
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" || true

  log "Importing DB from $latest_db ..."
  if ! zcat "$latest_db" | mysql "$DB_NAME"; then
    err "Database import failed."
    rm -rf "$TMP_DIR"
    return
  fi

  local TARGET_ROOT="/home/${domain}/public_html"
  mkdir -p "$TARGET_ROOT"

  local WP_EXTRACT_ROOT
  WP_EXTRACT_ROOT="$(dirname "$config")"

  log "Syncing WordPress files to $TARGET_ROOT ..."
  rsync -a --delete "$WP_EXTRACT_ROOT"/ "$TARGET_ROOT"/ || warn "rsync reported warnings."

  local owner group
  owner="$(stat -c '%U' "$TARGET_ROOT" 2>/dev/null || echo root)"
  group="$(stat -c '%G' "$TARGET_ROOT" 2>/dev/null || echo root)"
  log "Applying ownership ${owner}:${group} ..."
  chown -R "${owner}:${group}" "$TARGET_ROOT" 2>/dev/null || true

  log "Setting permissions..."
  find "$TARGET_ROOT" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$TARGET_ROOT" -type f -exec chmod 644 {} \; 2>/dev/null || true
  [[ -f "$TARGET_ROOT/wp-config.php" ]] && chmod 600 "$TARGET_ROOT/wp-config.php" 2>/dev/null || true

  rm -rf "$TMP_DIR"

  echo
  log "Migration restore completed for ${domain}."
}

main() {
  require_root
  check_tools

  case "${1-}" in
    --backup-only)
      # Old server backup mode for selected sites, plus optional rsync push
      do_old_server_backup --non-interactive
      ;;
    "" )
      echo
      echo "Select migration mode:"
      echo "  1) Old Server: Push sites from THIS server to another server (LOCAL backups + optional rsync)"
      echo "  2) New Server: Pull sites from another server to THIS server (restore from LOCAL backups)"
      echo

      local mode
      while :; do
        read -rp "Choose [1-2]: " mode
        case "$mode" in
          1) do_old_server_backup ; break ;;
          2) do_new_server_restore ; break ;;
          *) warn "Invalid choice."; ;;
        esac
      done
      ;;
    * )
      err "Unknown argument: $1"
      echo "Usage:"
      echo "  wp-migrate-local.sh                    # interactive wizard"
      echo "  wp-migrate-local.sh --backup-only      # backup selected sites locally (for migration, then optional rsync push)"
      exit 1
      ;;
  esac
}

main "$@"
