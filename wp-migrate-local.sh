#!/usr/bin/env bash
#
# wp-migrate-local.sh
#
# Local-only WordPress migration wizard:
#
# 1) Old Server:
#    - Create local backups in /root/wp-migrate/<domain>/.
#    - DB + files, no Dropbox involved.
#    - Optional rsync push of /root/wp-migrate to a remote NEW server.
#
# 2) New Server:
#    - Restore from local backups in /root/wp-migrate/<domain>/.
#
# --backup-only:
#    - Old server backup mode: let user select site(s), create local backups,
#      then offer rsync push to new server (ask only for NEW server IP).
#

set -euo pipefail

MIGRATE_ROOT="/root/wp-migrate"

log() { echo "[+] $*"; }
warn() { echo "[-] $*"; }
err() { echo "[!] $*" >&2; }

check_tools() {
  local missing=0
  for c in mysqldump mysql tar gzip rsync stat zcat sshpass wp; do
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
log "Detected WordPress installations and their sizes:"
local i=1
for wp in "${WP_PATHS[@]}"; do
  local db domain size
  db=$(grep -E "define\\(\\s*'DB_NAME'" "$wp/wp-config.php" 2>/dev/null | awk -F"'" '{print $4}')
  domain="$(basename "$(dirname "$wp")")"

  # Get the size of the WordPress directory (including wp-content, wp-includes, etc.)
  size=$(du -sh "$wp" 2>/dev/null | awk '{print $1}')  # Get human-readable size

  # Output the domain, DB name, and size
  echo "  [$i] $domain (DB: ${db:-UNKNOWN}, Path: $wp, Size: $size)"
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

  # Backup Process
  local TS
  TS="$(date +%Y%m%d-%H%M%S)"

  for wp in "${SELECTED_WP_PATHS[@]}"; do
    local db domain
    db=$(grep -E "define\\(\\s*'DB_NAME'" "$wp/wp-config.php" 2>/dev/null | awk -F"'" '{print $4}')
    domain="$(basename "$(dirname "$wp")")"
    if [[ -z "$db" ]]; then
      warn "Skipping $domain — cannot parse DB_NAME."
      continue
    fi
    # Ensure the domain directory exists
    domain_dir="${MIGRATE_ROOT}/${domain}"
    mkdir -p "$domain_dir"  # Create directory for the domain
    
    local DB_FILE="${MIGRATE_ROOT}/${domain}/${domain}-db-${TS}-migrate.sql.gz"
    local FILES_FILE="${MIGRATE_ROOT}/${domain}/${domain}-files-${TS}-migrate.tar.gz"

    echo
    log "Backing up $domain for migration..."
    log "  DB: $db"
    log "  Path: $wp"

  # DB backup using WP-CLI with --allow-root flag
  if ! wp db export "$DB_FILE" --path="$wp" --allow-root; then
    err "DB backup failed for $domain"
    continue
  fi
  log "    DB backup: $DB_FILE"

  # Lock the wp-content directory to prevent changes during backup
  domain_dir="${MIGRATE_ROOT}/${domain}"
  LOCK_FILE="/var/lock/wp-content-${domain}.lock"

  # Lock the directory for both DB and Files backup using flock
  (
    flock -n 200 || exit 1   # Create a lock to ensure the backup is not interrupted
    log "Backing up wp-content directory for $domain..."

  # Files backup using tar
  if ! tar -czf "$FILES_FILE" -C "$wp" .; then
    err "Files backup failed for $domain"
    continue
  fi
  log "    Files backup: $FILES_FILE"
) 200>$LOCK_FILE  # Lock file for the domain

  done

  log "Local migration backups created under: $MIGRATE_ROOT"
  log "Next step (for migration):"
  log "  - Copy $MIGRATE_ROOT to the new server (e.g. rsync or scp)"

 # Optionally push to remote server via rsync
read -rp "Do you want to PUSH $MIGRATE_ROOT to a remote NEW server now via rsync? (y/N): " push
if [[ "$push" =~ ^[Yy]$ ]]; then
  read -rp "Enter NEW server IP (e.g. 65.109.33.94): " NEW_IP
  read -rp "Enter SSH port for new server (default 22): " SSH_PORT
  SSH_PORT="${SSH_PORT:-22}"

  # Optional prompt for SSH password (if SSH keys are not configured)
  log "Pushing $MIGRATE_ROOT → root@$NEW_IP:/root/wp-migrate/"
  log "You may see a host key fingerprint prompt (first time only), then a password prompt."

  # First-time SSH to ensure host key is added (optional but nice UX)
  ssh -p "$SSH_PORT" root@"$NEW_IP" "echo 'SSH connectivity OK from $(hostname)'" || {
    err "SSH connectivity test failed. Aborting rsync."
    return
  }

  # Now run rsync (host key already accepted above)
  if ! rsync -avz -e "ssh -p $SSH_PORT" "$MIGRATE_ROOT"/ root@"$NEW_IP":/root/wp-migrate/; then
    err "rsync push failed. Please check SSH connectivity and rerun."
    return
  fi
fi
}

# Main entry point
main() {
  check_tools
  do_old_server_backup
}

main "$@"
