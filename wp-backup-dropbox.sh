#!/usr/bin/env bash
#
# wp-backup-dropbox.sh
#
# - Backup WordPress sites (DB + files) to Dropbox only (no local retention)
# - Per-domain structure:
#     dropbox:wp-backups/<domain>/
# - Retention on Dropbox:
#     - Daily: 7
#     - Weekly: 4
#     - Monthly: 2
# - Modes:
#     - (default) manual: interactive, lets you select sites (e.g. 1 2 5, or A for all)
#     - --auto-daily: non-interactive, backs up ALL sites (for cron)
#     - --auto-setup: run one auto-daily + install cron at 03:30
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
  for c in mysqldump tar gzip rclone find; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "Required command '$c' not found. Please install it (apt-get)."
      missing=1
    fi
  done
  if (( missing != 0 )); then
    exit 1
  fi

  if ! rclone listremotes 2>/dev/null | grep -q "^dropbox:"; then
    err "rclone remote 'dropbox' not configured."
    echo "Run: rclone config   and create a remote named 'dropbox' pointing to Dropbox."
    exit 1
  fi
}

discover_wp_paths() {
  mapfile -t WP_PATHS < <(
    find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null \
      | sed 's#/wp-config.php$##' | sort
  )
}

backup_wp_sites_to_dropbox() {
  local MODE="${1:-manual}"

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
    domain=$(basename "$(dirname "$wp")")
    echo "  [$i] $domain"
    echo "      Path: $wp"
    echo "      DB  : ${db:-UNKNOWN}"
    ((i++))
  done

  declare -a SELECTED_WP_PATHS=()

  if [[ "$MODE" == "manual" ]]; then
    echo
    read -rp "Backup which sites? (e.g. 1 2 5, or A for all): " selection

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

    echo
    read -rp "Backup these site(s) to Dropbox (DB + files, no local retention)? (y/N): " ok
    [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }
  else
    # AUTO (daily) mode: always back up ALL sites, no prompts
    SELECTED_WP_PATHS=("${WP_PATHS[@]}")
    log "AUTO mode: backing up ALL detected WordPress sites to Dropbox."
  fi

  local TS DOW DOM
  TS="$(date +%Y%m%d-%H%M%S)"
  DOW="$(date +%u)"   # 1-7 (Mon-Sun)
  DOM="$(date +%d)"   # 01-31

  for wp in "${SELECTED_WP_PATHS[@]}"; do
    local db domain
    db=$(grep -E "define\\(\\s*'DB_NAME'" "$wp/wp-config.php" 2>/dev/null | awk -F"'" '{print $4}')
    domain=$(basename "$(dirname "$wp")")

    if [[ -z "$db" ]]; then
      warn "Skipping $domain — could not parse DB_NAME from wp-config.php"
      continue
    fi

    local TMP_DIR
    TMP_DIR="$(mktemp -d "/tmp/wp-backup-${domain}-XXXXXX")"

    local label suffix
    if [[ "$MODE" == "daily" ]]; then
      label="daily"
    else
      label="manual"
    fi
    suffix="${TS}-${label}"

    local DB_FILE="${TMP_DIR}/${domain}-db-${suffix}.sql.gz"
    local FILES_FILE="${TMP_DIR}/${domain}-files-${suffix}.tar.gz"

    echo
    log "Backing up site: $domain"
    log "  DB   : $db"
    log "  Root : $wp"

    # DB backup
    log "  → Dumping database..."
    if [[ -f /root/.my.cnf ]]; then
      if mysqldump "$db" | gzip > "$DB_FILE"; then
        log "    DB backup created: $DB_FILE"
      else
        err "    DB backup failed for $db"
        rm -rf "$TMP_DIR"
        continue
      fi
    else
      warn "    /root/.my.cnf not found. You may be prompted..."
      if mysqldump -u root -p "$db" | gzip > "$DB_FILE"; then
        log "    DB backup created: $DB_FILE"
      else
        err "    DB backup failed for $db"
        rm -rf "$TMP_DIR"
        continue
      fi
    fi

    # Files backup
    log "  → Archiving WordPress files..."
    local parent base
    parent="$(dirname "$wp")"
    base="$(basename "$wp")"
    if tar -czf "$FILES_FILE" -C "$parent" "$base"; then
      log "    Files backup created: $FILES_FILE"
    else
      err "    Files backup failed for $domain"
      rm -rf "$TMP_DIR"
      continue
    fi

    # Upload to Dropbox
    local REMOTE_DIR="${DROPBOX_REMOTE}/${domain}"
    log "  → Uploading to Dropbox: ${REMOTE_DIR}"
    if rclone copy "$TMP_DIR" "$REMOTE_DIR" >/dev/null 2>&1; then
      log "    Upload completed."
    else
      warn "    Upload encountered issues. Check rclone / network."
    fi

    # AUTO retention only in daily mode
    if [[ "$MODE" == "daily" ]]; then
      local daily_db daily_files weekly_db weekly_files monthly_db monthly_files i

      # Daily: keep 7
      mapfile -t daily_db < <(rclone lsf --files-only --format "p" "$REMOTE_DIR" 2>/dev/null \
        | grep "${domain}-db-.*-daily\.sql\.gz" | sort -r || true)
      mapfile -t daily_files < <(rclone lsf --files-only --format "p" "$REMOTE_DIR" 2>/dev/null \
        | grep "${domain}-files-.*-daily\.tar\.gz" | sort -r || true)

      if ((${#daily_db[@]} > 7)); then
        for ((i=7; i<${#daily_db[@]}; i++)); do
          rclone delete "${REMOTE_DIR}/${daily_db[$i]}" >/dev/null 2>&1 || true
        done
      fi
      if ((${#daily_files[@]} > 7)); then
        for ((i=7; i<${#daily_files[@]}; i++)); do
          rclone delete "${REMOTE_DIR}/${daily_files[$i]}" >/dev/null 2>&1 || true
        done
      fi

      # Weekly: promote on Sunday, keep 4
      if [[ "$DOW" == "7" ]]; then
        local DAILY_DB_REMOTE DAILY_FILES_REMOTE
        DAILY_DB_REMOTE="${domain}-db-${TS}-daily.sql.gz"
        DAILY_FILES_REMOTE="${domain}-files-${TS}-daily.tar.gz"

        rclone copyto "${REMOTE_DIR}/${DAILY_DB_REMOTE}" "${REMOTE_DIR}/${domain}-db-${TS}-weekly.sql.gz" >/dev/null 2>&1 || true
        rclone copyto "${REMOTE_DIR}/${DAILY_FILES_REMOTE}" "${REMOTE_DIR}/${domain}-files-${TS}-weekly.tar.gz" >/dev/null 2>&1 || true

        mapfile -t weekly_db < <(rclone lsf --files-only --format "p" "$REMOTE_DIR" 2>/dev/null \
          | grep "${domain}-db-.*-weekly\.sql\.gz" | sort -r || true)
        mapfile -t weekly_files < <(rclone lsf --files-only --format "p" "$REMOTE_DIR" 2>/dev/null \
          | grep "${domain}-files-.*-weekly\.tar\.gz" | sort -r || true)

        if ((${#weekly_db[@]} > 4)); then
          for ((i=4; i<${#weekly_db[@]}; i++)); do
            rclone delete "${REMOTE_DIR}/${weekly_db[$i]}" >/dev/null 2>&1 || true
          done
        fi
        if ((${#weekly_files[@]} > 4)); then
          for ((i=4; i<${#weekly_files[@]}; i++)); do
            rclone delete "${REMOTE_DIR}/${weekly_files[$i]}" >/dev/null 2>&1 || true
          done
        fi
      fi

      # Monthly: promote on day 01, keep 2 months
      if [[ "$DOM" == "01" ]]; then
        local month_tag
        month_tag="$(date +%Y-%m)"
        local MONTHLY_DB_REMOTE="${domain}-db-${month_tag}-monthly.sql.gz"
        local MONTHLY_FILES_REMOTE="${domain}-files-${month_tag}-monthly.tar.gz"
        local DAILY_DB_REMOTE="${domain}-db-${TS}-daily.sql.gz"
        local DAILY_FILES_REMOTE="${domain}-files-${TS}-daily.tar.gz"

        rclone copyto "${REMOTE_DIR}/${DAILY_DB_REMOTE}" "${REMOTE_DIR}/${MONTHLY_DB_REMOTE}" >/dev/null 2>&1 || true
        rclone copyto "${REMOTE_DIR}/${DAILY_FILES_REMOTE}" "${REMOTE_DIR}/${MONTHLY_FILES_REMOTE}" >/dev/null 2>&1 || true

        mapfile -t monthly_db < <(rclone lsf --files-only --format "p" "$REMOTE_DIR" 2>/dev/null \
          | grep "${domain}-db-.*-monthly\.sql\.gz" | sort -r || true)
        mapfile -t monthly_files < <(rclone lsf --files-only --format "p" "$REMOTE_DIR" 2>/dev/null \
          | grep "${domain}-files-.*-monthly\.tar\.gz" | sort -r || true)

        if ((${#monthly_db[@]} > 2)); then
          for ((i=2; i<${#monthly_db[@]}; i++)); do
            rclone delete "${REMOTE_DIR}/${monthly_db[$i]}" >/dev/null 2>&1 || true
          done
        fi
        if ((${#monthly_files[@]} > 2)); then
          for ((i=2; i<${#monthly_files[@]}; i++)); do
            rclone delete "${REMOTE_DIR}/${monthly_files[$i]}" >/dev/null 2>&1 || true
          done
        fi
      fi
    fi

    rm -rf "$TMP_DIR"
  done

  echo
  log "Backups completed. All retained copies are in Dropbox only."
}

setup_cron() {
  local CRON_SCRIPT="/usr/local/bin/wp-auto-backup-dropbox.sh"
  local CRON_FILE="/etc/cron.d/wp-auto-backup-dropbox"
  local REPO_BASE="https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main"

  log "Creating helper cron script: $CRON_SCRIPT"

  cat > "$CRON_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
bash <(curl -fsSL "${REPO_BASE}/wp-backup-dropbox.sh") --auto-daily
EOF

  chmod +x "$CRON_SCRIPT"

  log "Creating daily cron job at 03:30 in: $CRON_FILE"
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

30 3 * * * root $CRON_SCRIPT >/var/log/wp-auto-backup-dropbox.log 2>&1
EOF

  log "Cron installed. Daily backups to Dropbox (03:30) enabled."
}

main() {
  require_root
  check_tools

  case "${1-}" in
    --auto-daily)
      backup_wp_sites_to_dropbox "daily"
      ;;
    --auto-setup)
      echo "This will:"
      echo "  - Run one AUTO DAILY backup now (ALL sites)"
      echo "  - Install a daily cron job at 03:30"
      read -rp "Proceed? (y/N): " ok
      [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; exit 0; }
      backup_wp_sites_to_dropbox "daily"
      setup_cron
      ;;
    *)
      backup_wp_sites_to_dropbox "manual"
      ;;
  esac
}

main "$@"
