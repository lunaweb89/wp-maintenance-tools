#!/usr/bin/env bash
#
# wp-restore-dropbox.sh
#
# Restore one WordPress site from Dropbox:
#   - Uses: dropbox:wp-backups/<domain>/
#   - Picks the latest DB + files
#   - Parses DB_NAME/DB_USER/DB_PASSWORD from wp-config.php
#   - Creates DB + user
#   - Imports DB + syncs files into /home/<domain>/public_html
#

set -euo pipefail

DROPBOX_REMOTE="dropbox:wp-backups"

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
  for c in rclone mysql rsync tar zcat stat; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "Required command '$c' not found. Please install it."
      missing=1
    fi
  done
  if (( missing != 0 )); then
    exit 1
  fi

  if ! rclone listremotes 2>/dev/null | grep -q "^dropbox:"; then
    err "rclone remote 'dropbox' not configured."
    echo "Run: rclone config   and create 'dropbox' remote."
    exit 1
  fi
}

main() {
  require_root
  check_tools

  log "Listing sites under ${DROPBOX_REMOTE}..."
  mapfile -t DOMAINS < <(rclone lsd "$DROPBOX_REMOTE" 2>/dev/null | awk '{print $5}' | sort)
  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    warn "No site folders found in Dropbox wp-backups."
    exit 0
  fi

  echo
  echo "Available backup sites:"
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
  local LOCAL_RESTORE_DIR="/root/wp-restore/${domain}"
  mkdir -p "$LOCAL_RESTORE_DIR"

  echo
  log "Syncing backups for $domain from Dropbox..."
  if ! rclone sync "${DROPBOX_REMOTE}/${domain}" "$LOCAL_RESTORE_DIR"; then
    err "rclone sync failed."
    exit 1
  fi

  local latest_db latest_files
  latest_db="$(ls -1t "${LOCAL_RESTORE_DIR}/${domain}-db-"*.sql.gz 2>/dev/null | head -n1 || true)"
  latest_files="$(ls -1t "${LOCAL_RESTORE_DIR}/${domain}-files-"*.tar.gz 2>/dev/null | head -n1 || true)"

  if [[ -z "$latest_db" || -z "$latest_files" ]]; then
    err "Could not find DB and files backups for $domain in ${LOCAL_RESTORE_DIR}."
    exit 1
  fi

  log "Using DB backup   : $latest_db"
  log "Using FILES backup: $latest_files"

  local TMP_DIR
  TMP_DIR="$(mktemp -d "/tmp/wp-restore-${domain}-XXXXXX")"

  if ! tar -xzf "$latest_files" -C "$TMP_DIR"; then
    err "Failed to extract files archive."
    rm -rf "$TMP_DIR"
    exit 1
  fi

  local config
  config="$(find "$TMP_DIR" -maxdepth 4 -name 'wp-config.php' | head -n1 || true)"
  if [[ -z "$config" ]]; then
    err "Could not find wp-config.php in backup."
    rm -rf "$TMP_DIR"
    exit 1
  fi

  local DB_NAME DB_USER DB_PASS
  DB_NAME="$(grep -E "define\\(\\s*'DB_NAME'" "$config" | awk -F"'" '{print $4}')"
  DB_USER="$(grep -E "define\\(\\s*'DB_USER'" "$config" | awk -F"'" '{print $4}')"
  DB_PASS="$(grep -E "define\\(\\s*'DB_PASSWORD'" "$config" | awk -F"'" '{print $4}')"

  if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
    err "Failed to parse DB_NAME/DB_USER/DB_PASSWORD from wp-config.php"
    rm -rf "$TMP_DIR"
    exit 1
  fi

  echo
  log "Parsed DB credentials:"
  echo "  DB_NAME: $DB_NAME"
  echo "  DB_USER: $DB_USER"
  echo "  DB_PASS: (hidden)"

  echo
  read -rp "Proceed with RESTORE (may overwrite /home/${domain}/public_html)? (y/N): " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; rm -rf "$TMP_DIR"; exit 0; }

  mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" || true
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" || true

  log "Importing DB from $latest_db ..."
  if ! zcat "$latest_db" | mysql "$DB_NAME"; then
    err "Database import failed."
    rm -rf "$TMP_DIR"
    exit 1
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

  log "Adjusting permissions..."
  find "$TARGET_ROOT" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$TARGET_ROOT" -type f -exec chmod 644 {} \; 2>/dev/null || true
  [[ -f "$TARGET_ROOT/wp-config.php" ]] && chmod 600 "$TARGET_ROOT/wp-config.php" 2>/dev/null || true

  rm -rf "$TMP_DIR"

  echo
  log "Restore completed for $domain."
  echo "Please test the site in browser and confirm."
}

main "$@"
