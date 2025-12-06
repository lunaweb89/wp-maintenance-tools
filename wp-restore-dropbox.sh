#!/usr/bin/env bash
#
# wp-restore-dropbox.sh
#
# Restore WordPress site (DB + files) from Dropbox via rclone.
#
# Layout expected:
#   dropbox:wp-backups/<domain>/<domain>-db-YYYYMMDD-HHMMSS-*.sql.gz
#   dropbox:wp-backups/<domain>/<domain>-files-YYYYMMDD-HHMMSS-*.tar.gz
#
# - Auto-detects DB name/user/pass from wp-config.php in the archive
# - Restores to /home/<domain>/public_html
#

set -euo pipefail

log()  { echo "[+] $*"; }
warn() { echo "[-] $*"; }
err()  { echo "[!] $*" >&2; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root."
    echo "Use the toolkit launcher instead:"
    echo "  curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \\"
    echo "    | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )"
    exit 1
  fi
}

check_tools() {
  local missing=0
  for c in rclone mysql rsync tar zcat stat; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "Required command '$c' not found. Install with apt-get."
      missing=1
    fi
  done
  if (( missing != 0 )); then
    exit 1
  fi

  if ! rclone listremotes 2>/dev/null | grep -q '^dropbox:'; then
    err "rclone remote 'dropbox' not configured."
    echo "Configure it first with: rclone config"
    exit 1
  fi
}

select_domain_from_dropbox() {
  # List domain folders under dropbox:wp-backups
  mapfile -t DOMAINS < <(rclone lsd "dropbox:wp-backups" 2>/dev/null | awk '{print $5}' | sort)

  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    err "No domain folders found under dropbox:wp-backups"
    exit 1
  fi

  echo
  echo "Available domains in Dropbox backups:"
  local i=1
  for d in "${DOMAINS[@]}"; do
    echo "  [$i] $d"
    ((i++))
  done
  echo

  local sel
  while :; do
    read -rp "Select a domain to restore [1-${#DOMAINS[@]}]: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] || { warn "Enter a number."; continue; }
    (( sel >= 1 && sel <= ${#DOMAINS[@]} )) || { warn "Out of range."; continue; }
    break
  done

  RESTORE_DOMAIN="${DOMAINS[sel-1]}"
}

main() {
  require_root
  check_tools
  select_domain_from_dropbox

  local REMOTE_DIR="dropbox:wp-backups/${RESTORE_DOMAIN}"

  # List backups and pick latest DB and files by name
  mapfile -t DB_FILES < <(rclone lsf "$REMOTE_DIR" 2>/dev/null | grep '-db-' | sort)
  mapfile -t FILES_FILES < <(rclone lsf "$REMOTE_DIR" 2>/dev/null | grep '-files-' | sort)

  if [[ ${#DB_FILES[@]} -eq 0 || ${#FILES_FILES[@]} -eq 0 ]]; then
    err "Could not find DB and files backups for ${RESTORE_DOMAIN} in ${REMOTE_DIR}"
    exit 1
  fi

  local LATEST_DB="${DB_FILES[-1]}"
  local LATEST_FILES="${FILES_FILES[-1]}"

  echo
  log "Using DB backup   : ${REMOTE_DIR}/${LATEST_DB}"
  log "Using FILES backup: ${REMOTE_DIR}/${LATEST_FILES}"

  local TMP_DIR
  TMP_DIR="$(mktemp -d "/tmp/wp-restore-dropbox-${RESTORE_DOMAIN}-XXXXXX")"

  log "Downloading backups from Dropbox to temp dir..."
  rclone copy "${REMOTE_DIR}/${LATEST_DB}" "$TMP_DIR" >/dev/null 2>&1
  rclone copy "${REMOTE_DIR}/${LATEST_FILES}" "$TMP_DIR" >/dev/null 2>&1

  local LOCAL_DB="${TMP_DIR}/${LATEST_DB}"
  local LOCAL_FILES="${TMP_DIR}/${LATEST_FILES}"

  log "Extracting files archive..."
  if ! tar -xzf "$LOCAL_FILES" -C "$TMP_DIR"; then
    err "Failed to extract files archive."
    rm -rf "$TMP_DIR"
    exit 1
  fi

  local config
  config="$(find "$TMP_DIR" -maxdepth 5 -name 'wp-config.php' | head -n1 || true)"
  if [[ -z "$config" ]]; then
    err "Could not find wp-config.php in extracted files."
    rm -rf "$TMP_DIR"
    exit 1
  fi

  local DB_NAME DB_USER DB_PASS
  DB_NAME="$(grep -E "define\(\s*'DB_NAME'" "$config" | awk -F"'" '{print $4}')"
  DB_USER="$(grep -E "define\(\s*'DB_USER'" "$config" | awk -F"'" '{print $4}')"
  DB_PASS="$(grep -E "define\(\s*'DB_PASSWORD'" "$config" | awk -F"'" '{print $4}')"

  if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
    err "Failed to parse DB credentials from wp-config.php."
    rm -rf "$TMP_DIR"
    exit 1
  fi

  echo
  log "Parsed DB credentials:"
  echo "  DB_NAME: $DB_NAME"
  echo "  DB_USER: $DB_USER"
  echo "  DB_PASS: (hidden)"

  echo
  read -rp "Proceed with RESTORE for ${RESTORE_DOMAIN} on THIS server? (y/N): " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; rm -rf "$TMP_DIR"; exit 0; }

  mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" || true
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" || true

  log "Importing DB from ${LOCAL_DB} ..."
  if ! zcat "$LOCAL_DB" | mysql "$DB_NAME"; then
    err "Database import failed."
    rm -rf "$TMP_DIR"
    exit 1
  fi

  local TARGET_ROOT="/home/${RESTORE_DOMAIN}/public_html"
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
  log "Restore from Dropbox completed for ${RESTORE_DOMAIN}."
}

main "$@"
