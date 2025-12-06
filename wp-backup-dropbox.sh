#!/usr/bin/env bash
#
# wp-backup-dropbox.sh
#
# Backup WordPress sites (DB + files) directly to Dropbox via rclone.
#
# Modes:
#   No args      → Interactive per-site backup (manual)
#   --auto-setup → Run a full backup of ALL WP sites now, then install a daily cron
#
# Dropbox layout:
#   dropbox:wp-backups/<domain>/<domain>-db-YYYYMMDD-HHMMSS.sql.gz
#   dropbox:wp-backups/<domain>/<domain>-files-YYYYMMDD-HHMMSS.tar.gz
#
# No long-term local backups are kept; only temp files.
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
  for c in mysqldump tar gzip rclone find; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "Required command '$c' not found. Install with apt-get."
      missing=1
    fi
  done
  if (( missing != 0 )); then
    exit 1
  fi

  # Check rclone remote "dropbox"
  if ! rclone listremotes 2>/dev/null | grep -q '^dropbox:'; then
    err "rclone remote 'dropbox' not configured."
    echo "Configure it first with: rclone config"
    exit 1
  fi
}

discover_wp_paths() {
  mapfile -t WP_PATHS < <(
    find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null \
      | sed 's#/wp-config.php$##' | sort
  )
}

select_sites_manual() {
  discover_wp_paths
  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found under /home."
    exit 0
  fi

  echo
  log "Detected WordPress installations:"
  local i=1
  for wp in "${WP_PATHS[@]}"; do
    local user_dir domain config db_name
    user_dir="$(dirname "$wp")"
    domain="$(basename "$user_dir")"
    config="${wp}/wp-config.php"
    db_name="$(grep -E "define\(\s*'DB_NAME'" "$config" 2>/dev/null | awk -F"'" '{print $4}')"
    echo "  [$i] ${domain} (DB: ${db_name:-UNKNOWN}, Path: ${wp})"
    ((i++))
  done

  echo
  read -rp "Backup which sites? (e.g. 1 2 5, or A for all): " selection

  SELECTED_WP_PATHS=()

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
      exit 1
    fi
  fi

  echo
  log "You selected ${#SELECTED_WP_PATHS[@]} site(s) to back up to Dropbox:"
  for wp in "${SELECTED_WP_PATHS[@]}"; do
    local domain
    domain="$(basename "$(dirname "$wp")")"
    echo "  - $domain ($wp)"
  done

  echo
  read -rp "Proceed with Dropbox backup for these site(s)? (y/N): " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; exit 0; }
}

backup_one_site_to_dropbox() {
  local wp_path="$1"
  local label="${2:-manual}"

  local user_dir domain
  user_dir="$(dirname "$wp_path")"
  domain="$(basename "$user_dir")"

  local config db_name
  config="${wp_path}/wp-config.php"
  db_name="$(grep -E "define\(\s*'DB_NAME'" "$config" 2>/dev/null | awk -F"'" '{print $4}')"

  if [[ -z "$db_name" ]]; then
    warn "Skipping ${domain} — cannot parse DB_NAME from ${config}."
    return
  fi

  local TMP_DIR
  TMP_DIR="$(mktemp -d "/tmp/wp-backup-dropbox-${domain}-XXXXXX")"

  local TS
  TS="$(date +%Y%m%d-%H%M%S)"

  local DB_FILE="${TMP_DIR}/${domain}-db-${TS}-${label}.sql.gz"
  local FILES_FILE="${TMP_DIR}/${domain}-files-${TS}-${label}.tar.gz"
  local REMOTE_DIR="dropbox:wp-backups/${domain}"

  echo
  log "Backing up ${domain} to Dropbox..."
  log "  Local tmp dir: ${TMP_DIR}"
  log "  Remote dir   : ${REMOTE_DIR}"

  # DB dump
  if [[ -f /root/.my.cnf ]]; then
    if ! mysqldump "$db_name" | gzip > "$DB_FILE"; then
      err "DB backup failed for ${db_name}"
      rm -rf "$TMP_DIR"
      return
    fi
  else
    warn "/root/.my.cnf not found. You may be prompted for MySQL root password..."
    if ! mysqldump -u root -p "$db_name" | gzip > "$DB_FILE"; then
      err "DB backup failed for ${db_name}"
      rm -rf "$TMP_DIR"
      return
    fi
  fi

  # Files tar
  local parent base
  parent="$(dirname "$wp_path")"
  base="$(basename "$wp_path")"
  if ! tar -czf "$FILES_FILE" -C "$parent" "$base"; then
    err "Files backup failed for ${domain}"
    rm -rf "$TMP_DIR"
    return
  fi

  # Upload to Dropbox
  if ! rclone copy "$TMP_DIR" "$REMOTE_DIR" >/dev/null 2>&1; then
    err "rclone upload failed for ${domain}"
    rm -rf "$TMP_DIR"
    return
  fi

  # Retention: keep last 7 backups per domain (per DB and files separately)
  log "Applying simple retention (last 7 backups) for ${domain}..."

  # List and trim DB backups
  mapfile -t REMOTE_DB_FILES < <(rclone lsjson "${REMOTE_DIR}" 2>/dev/null | jq -r '.[] | select(.Name | test("-db-")) | .Name' | sort)
  local count="${#REMOTE_DB_FILES[@]}"
  if (( count > 7 )); then
    local to_delete=$((count - 7))
    for ((i=0; i<to_delete; i++)); do
      rclone delete "${REMOTE_DIR}/${REMOTE_DB_FILES[i]}" || true
    done
  fi

  # List and trim FILE backups
  mapfile -t REMOTE_FILE_FILES < <(rclone lsjson "${REMOTE_DIR}" 2>/dev/null | jq -r '.[] | select(.Name | test("-files-")) | .Name' | sort)
  count="${#REMOTE_FILE_FILES[@]}"
  if (( count > 7 )); then
    local to_delete2=$((count - 7))
    for ((i=0; i<to_delete2; i++)); do
      rclone delete "${REMOTE_DIR}/${REMOTE_FILE_FILES[i]}" || true
    done
  fi

  rm -rf "$TMP_DIR"
  log "Backup for ${domain} completed and uploaded to Dropbox."
}

run_manual_mode() {
  select_sites_manual

  for wp in "${SELECTED_WP_PATHS[@]}"; do
    backup_one_site_to_dropbox "$wp" "manual"
  done

  echo
  log "Manual Dropbox backup completed."
}

backup_all_sites_auto() {
  discover_wp_paths
  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found under /home."
    return
  fi

  log "Auto-backup: backing up ALL WordPress sites to Dropbox..."
  for wp in "${WP_PATHS[@]}"; do
    backup_one_site_to_dropbox "$wp" "daily"
  done
}

setup_cron() {
  local CRON_SCRIPT="/usr/local/bin/wp-auto-backup-dropbox.sh"
  local CRON_FILE="/etc/cron.d/wp-auto-backup-dropbox"

  cat > "$CRON_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_BASE="https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main"

# Run auto backup (all sites → Dropbox, label=daily)
curl -fsSL "${REPO_BASE}/wp-backup-dropbox.sh" | bash -s -- --auto-run
EOF

  chmod +x "$CRON_SCRIPT"

  # Daily at 03:30, log to /var/log/wp-auto-backup-dropbox.log
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

30 3 * * * root ${CRON_SCRIPT} >> /var/log/wp-auto-backup-dropbox.log 2>&1
EOF

  log "Cron installed: daily Dropbox backup at 03:30"
}

main() {
  require_root
  check_tools

  case "${1-}" in
    --auto-setup)
      echo
      log "Auto-setup: this will run an immediate full backup of ALL WP sites to Dropbox,"
      log "then install a daily cron job at 03:30."
      echo
      read -rp "Proceed with AUTO setup? (y/N): " ok
      [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; exit 0; }

      backup_all_sites_auto
      setup_cron
      ;;
    --auto-run)
      # Called from cron helper script: run all-site backup only, no prompts
      backup_all_sites_auto
      ;;
    *)
      run_manual_mode
      ;;
  esac
}

main "$@"
