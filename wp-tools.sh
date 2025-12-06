#!/usr/bin/env bash
#
# wp-tools.sh
#
# Master menu for WordPress maintenance tools:
#   [1] DB cleanup (WooCommerce order pruning)
#   [2] Malware scan (Maldet + ClamAV)
#   [3] Backup ALL MySQL/MariaDB databases
#   [4] Backup ONLY WordPress sites (DB + files)
#   [5] Exit
#   [6] Restore WordPress from Dropbox (DB + files)
#   [7] WordPress migration wizard (Old/New server via Dropbox)
#   [8] Auto Backups to Dropbox (run now + install daily cron)
#   [9] Fix WordPress file permissions
#   [10] WordPress health audit
#
# Run directly from GitHub (as root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-tools.sh)
#

set -uo pipefail

COLOR_RED="$(tput setaf 1 2>/dev/null || echo "")"
COLOR_GREEN="$(tput setaf 2 2>/dev/null || echo "")"
COLOR_YELLOW="$(tput setaf 3 2>/dev/null || echo "")"
COLOR_BLUE="$(tput setaf 4 2>/dev/null || echo "")"
COLOR_RESET="$(tput sgr0 2>/dev/null || echo "")"

REPO_BASE="https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main"
BACKUP_ROOT="/root/wp-backups"     # /root/wp-backups/<domain>/
DROPBOX_REMOTE="dropbox:wp-backups"

log() { echo -e "${COLOR_BLUE}[+]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[-]${COLOR_RESET} $*"; }
err() { echo -e "${COLOR_RED}[!] $*${COLOR_RESET}" >&2; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root (e.g. sudo bash ...)."
    exit 1
  fi
}

check_install_pkg() {
  local cmd="$1"
  local pkg="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Installing missing package: $pkg (for $cmd)..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$pkg" >/dev/null 2>&1 || true
  fi
}

auto_install_requirements() {
  log "Checking & installing required packages..."

  check_install_pkg "curl" "curl"
  check_install_pkg "unzip" "unzip"
  check_install_pkg "mysqldump" "mariadb-client"
  check_install_pkg "mysql" "mariadb-client"
  check_install_pkg "rclone" "rclone"

  # Maldet
  if ! command -v maldet >/dev/null 2>&1; then
    warn "Maldet not found — installing..."
    cd /tmp || exit 1
    wget -q http://www.rfxn.com/downloads/maldetect-current.tar.gz || true
    if [[ -f maldetect-current.tar.gz ]]; then
      tar -xzf maldetect-current.tar.gz
      cd maldetect-* 2>/dev/null || true
      bash install.sh >/dev/null 2>&1 || true
      log "Maldet installed (if install.sh succeeded)."
    else
      warn "Could not download Maldet; please check connectivity if you need it."
    fi
  fi

  # ClamAV
  if ! command -v clamscan >/dev/null 2>&1; then
    warn "ClamAV not found — installing..."
    apt-get install -y clamav clamav-daemon >/dev/null 2>&1 || true
    systemctl stop clamav-freshclam >/dev/null 2>&1 || true
    freshclam >/dev/null 2>&1 || true
    systemctl start clamav-freshclam >/dev/null 2>&1 || true
    log "ClamAV installed (signatures updated if possible)."
  fi

  log "Base requirements installed."
}

# ------------------ COMMON: DISCOVER WORDPRESS INSTALLS -------------------
discover_wp_paths() {
  # Global WP_PATHS array with wp root directories (where wp-config.php lives)
  mapfile -t WP_PATHS < <(
    find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null \
      | sed 's#/wp-config.php$##' | sort
  )
}

# ------------------------- BACKUP ALL DATABASES ---------------------------
backup_all_databases() {
  log "MySQL/MariaDB FULL backup selected."

  local BACKUP_DIR="/root/mysql-backups"
  mkdir -p "$BACKUP_DIR"

  local TS
  TS="$(date +%Y%m%d-%H%M%S)"
  local FILE="${BACKUP_DIR}/all-databases-${TS}.sql.gz"

  echo
  log "Backup file: $FILE"
  echo "  - Uses: mysqldump --all-databases | gzip"
  echo

  read -rp "Proceed with full DB backup? (y/N): " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { warn "Backup cancelled."; return; }

  log "Starting full database backup..."

  if [[ -f /root/.my.cnf ]]; then
    if mysqldump --all-databases | gzip > "$FILE"; then
      log "Backup completed successfully."
    else
      err "Backup failed. Removing partial file."
      rm -f "$FILE"
    fi
  else
    warn "/root/.my.cnf not found. You will be prompted for MySQL root password."
    if mysqldump -u root -p --all-databases | gzip > "$FILE"; then
      log "Backup completed successfully."
    else
      err "Backup failed. Removing partial file."
      rm -f "$FILE"
    fi
  fi
}

# ----------------- BACKUP ONLY WORDPRESS (DB + FILES) ---------------------
# Used by Option 4 (manual) and Option 8 (auto, daily/cron) via MODE param.
# MODE: "manual" or "daily"
backup_wp_sites_full() {
  local MODE="${1:-manual}"

  discover_wp_paths
  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found under /home."
    return
  fi

  mkdir -p "$BACKUP_ROOT"

  echo
  log "Detected WordPress installations:"
  for wp in "${WP_PATHS[@]}"; do
    local db domain
    db=$(grep -E "define\(\s*'DB_NAME'" "$wp/wp-config.php" 2>/dev/null | awk -F"'" '{print $4}')
    domain=$(basename "$(dirname "$wp")")
    echo "  - $domain"
    echo "      Path: $wp"
    echo "      DB  : ${db:-UNKNOWN}"
  done

  if [[ "$MODE" == "manual" ]]; then
    echo
    read -rp "Create MANUAL backups (DB + files) for all sites? (y/N): " ok
    [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }
  else
    log "Running AUTO backup (mode=$MODE) for all detected WordPress sites..."
  fi

  local TS
  TS="$(date +%Y%m%d-%H%M%S)"
  local DOW DOM
  DOW="$(date +%u)"   # 1-7 (Mon-Sun)
  DOM="$(date +%d)"   # 01-31

  for wp in "${WP_PATHS[@]}"; do
    local db domain domain_dir
    db=$(grep -E "define\(\s*'DB_NAME'" "$wp/wp-config.php" 2>/dev/null | awk -F"'" '{print $4}')
    domain=$(basename "$(dirname "$wp")")
    domain_dir="${BACKUP_ROOT}/${domain}"
    mkdir -p "$domain_dir"

    if [[ -z "$db" ]]; then
      warn "Skipping $domain — could not parse DB_NAME from wp-config.php"
      continue
    fi

    local label suffix
    if [[ "$MODE" == "daily" ]]; then
      label="daily"
    else
      label="manual"
    fi

    suffix="${TS}-${label}"
    local DB_FILE="${domain_dir}/${domain}-db-${suffix}.sql.gz"
    local FILES_FILE="${domain_dir}/${domain}-files-${suffix}.tar.gz"

    echo
    log "Backing up site: $domain"
    log "  DB   : $db"
    log "  Root : $wp"

    # --- DB backup ---
    log "  → Dumping database..."
    if [[ -f /root/.my.cnf ]]; then
      if mysqldump "$db" | gzip > "$DB_FILE"; then
        log "    DB backup: $DB_FILE"
      else
        err "    DB backup failed for $db"
        rm -f "$DB_FILE"
        continue
      fi
    else
      warn "    /root/.my.cnf not found. You may be prompted for DB password..."
      if mysqldump -u root -p "$db" | gzip > "$DB_FILE"; then
        log "    DB backup: $DB_FILE"
      else
        err "    DB backup failed for $db"
        rm -f "$DB_FILE"
        continue
      fi
    fi

    # --- Files backup ---
    log "  → Archiving WordPress files..."
    local parent base
    parent="$(dirname "$wp")"      # e.g. /home/maslike.es
    base="$(basename "$wp")"       # e.g. public_html
    if tar -czf "$FILES_FILE" -C "$parent" "$base"; then
      log "    Files backup: $FILES_FILE"
    else
      err "    Files backup failed for $domain"
      rm -f "$FILES_FILE"
      continue
    fi

    # --- Retention & promotions (ONLY FOR daily mode) ---
    if [[ "$MODE" == "daily" ]]; then
      # Keep last 7 daily DB/files
      local db_dailies files_dailies
      mapfile -t db_dailies < <(ls -1t "${domain_dir}/${domain}-db-"*-daily.sql.gz 2>/dev/null || true)
      mapfile -t files_dailies < <(ls -1t "${domain_dir}/${domain}-files-"*-daily.tar.gz 2>/dev/null || true)

      local i
      if ((${#db_dailies[@]} > 7)); then
        for ((i=7; i<${#db_dailies[@]}; i++)); do
          rm -f "${db_dailies[$i]}"
        done
      fi
      if ((${#files_dailies[@]} > 7)); then
        for ((i=7; i<${#files_dailies[@]}; i++)); do
          rm -f "${files_dailies[$i]}"
        done
      fi

      # Weekly promotion (Sunday)
      if [[ "$DOW" == "7" ]]; then
        local WEEKLY_DB="${domain_dir}/${domain}-db-${TS}-weekly.sql.gz"
        local WEEKLY_FILES="${domain_dir}/${domain}-files-${TS}-weekly.tar.gz"
        cp -f "$DB_FILE" "$WEEKLY_DB"
        cp -f "$FILES_FILE" "$WEEKLY_FILES"

        mapfile -t weekly_db < <(ls -1t "${domain_dir}/${domain}-db-"*-weekly.sql.gz 2>/dev/null || true)
        mapfile -t weekly_files < <(ls -1t "${domain_dir}/${domain}-files-"*-weekly.tar.gz 2>/dev/null || true)
        if ((${#weekly_db[@]} > 4)); then
          for ((i=4; i<${#weekly_db[@]}; i++)); do
            rm -f "${weekly_db[$i]}"
          done
        fi
        if ((${#weekly_files[@]} > 4)); then
          for ((i=4; i<${#weekly_files[@]}; i++)); do
            rm -f "${weekly_files[$i]}"
          done
        fi
      fi

      # Monthly promotion (1st of month)
      if [[ "$DOM" == "01" ]]; then
        local month_tag
        month_tag="$(date +%Y-%m)"
        local MONTHLY_DB="${domain_dir}/${domain}-db-${month_tag}-monthly.sql.gz"
        local MONTHLY_FILES="${domain_dir}/${domain}-files-${month_tag}-monthly.tar.gz"
        cp -f "$DB_FILE" "$MONTHLY_DB"
        cp -f "$FILES_FILE" "$MONTHLY_FILES"

        mapfile -t monthly_db < <(ls -1t "${domain_dir}/${domain}-db-"*-monthly.sql.gz 2>/dev/null || true)
        mapfile -t monthly_files < <(ls -1t "${domain_dir}/${domain}-files-"*-monthly.tar.gz 2>/dev/null || true)
        if ((${#monthly_db[@]} > 2)); then
          for ((i=2; i<${#monthly_db[@]}; i++)); do
            rm -f "${monthly_db[$i]}"
          done
        fi
        if ((${#monthly_files[@]} > 2)); then
          for ((i=2; i<${#monthly_files[@]}; i++)); do
            rm -f "${monthly_files[$i]}"
          done
        fi
      fi
    fi
  done

  echo
  log "WordPress site backups completed (MODE=${MODE})."
  log "Backup root: ${BACKUP_ROOT}"
}

backup_wp_databases() {
  # Wrapper to keep your existing menu behavior but now backups DB+files.
  backup_wp_sites_full "manual"
}

# ---------------------- SYNC BACKUPS TO DROPBOX ---------------------------
sync_backups_to_dropbox() {
  if ! command -v rclone >/dev/null 2>&1; then
    err "rclone not found. Cannot sync to Dropbox."
    return 1
  fi

  # Check remote exists
  if ! rclone listremotes 2>/dev/null | grep -q "^dropbox:"; then
    err "rclone remote 'dropbox' not configured."
    echo "To configure, run: rclone config"
    echo "Then create a remote named 'dropbox' pointing to your Dropbox."
    return 1
  fi

  if [[ ! -d "$BACKUP_ROOT" ]]; then
    warn "No local backups found at $BACKUP_ROOT to sync."
    return 0
  fi

  log "Syncing /root/wp-backups to Dropbox: ${DROPBOX_REMOTE} ..."
  rclone sync "$BACKUP_ROOT" "$DROPBOX_REMOTE" >/dev/null 2>&1 && \
    log "Dropbox sync completed." || \
    warn "Dropbox sync encountered errors. Check rclone logs or run manually."
}

# ---------------------- AUTO-BACKUP TO DROPBOX (CRON) ---------------------
run_auto_backup_to_dropbox() {
  log "Running AUTO backup (daily) for all WordPress sites..."
  backup_wp_sites_full "daily"
  log "Syncing backups to Dropbox..."
  sync_backups_to_dropbox
  log "AUTO backup + Dropbox sync completed."
}

setup_auto_backup_cron() {
  local CRON_SCRIPT="/usr/local/bin/wp-auto-backup-dropbox.sh"
  local CRON_FILE="/etc/cron.d/wp-auto-backup-dropbox"

  log "Creating helper script for cron: $CRON_SCRIPT"

  cat > "$CRON_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Non-interactive daily auto-backup + Dropbox sync wrapper
set -uo pipefail
# Adjust path if wp-tools.sh is stored elsewhere
WP_TOOLS="/root/wp-tools.sh"
if [[ ! -x "$WP_TOOLS" ]]; then
  # Try fallback: search PATH
  if command -v wp-tools.sh >/dev/null 2>&1; then
    WP_TOOLS="$(command -v wp-tools.sh)"
  fi
fi
if [[ ! -f "$WP_TOOLS" ]]; then
  echo "[!] wp-tools.sh not found at $WP_TOOLS; auto-backup aborted."
  exit 1
fi

bash "$WP_TOOLS" --auto-backup-to-dropbox
EOF

  chmod +x "$CRON_SCRIPT"

  log "Creating daily cron job in: $CRON_FILE"
  # Runs every day at 03:30 as root
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

30 3 * * * root $CRON_SCRIPT >/var/log/wp-auto-backup-dropbox.log 2>&1
EOF

  log "Cron job installed. Daily auto-backups to Dropbox enabled (03:30)."
}

auto_backups_to_dropbox() {
  log "=== Auto Backups to Dropbox ==="
  echo "This will:"
  echo "  - Create DAILY WordPress backups (DB + files) under ${BACKUP_ROOT}"
  echo "  - Sync them to Dropbox: ${DROPBOX_REMOTE}"
  echo "  - Install a daily cron job at 03:30"
  echo
  read -rp "Run one AUTO backup now and install cron? (y/N): " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { warn "Auto backup setup cancelled."; return; }

  run_auto_backup_to_dropbox
  setup_auto_backup_cron
}

# ----------------------------- DB CLEANUP TOOL ----------------------------
run_cleanup_script() {
  log "Launching DB cleanup tool (cleanup-script.sh)..."
  bash <(curl -fsSL "${REPO_BASE}/cleanup-script.sh")
}

# ----------------------------- MALWARE SCAN -------------------------------
run_malware_scan() {
  log "Launching malware scan tool (wp-malware-scan.sh)..."
  bash <(curl -fsSL "${REPO_BASE}/wp-malware-scan.sh")
}

# -------------------------- RESTORE FROM DROPBOX --------------------------
restore_wordpress_from_dropbox() {
  if ! command -v rclone >/dev/null 2>&1; then
    err "rclone not found; cannot restore from Dropbox."
    return
  fi

  if ! rclone listremotes 2>/dev/null | grep -q "^dropbox:"; then
    err "rclone remote 'dropbox' not configured."
    echo "Run: rclone config   and create 'dropbox' remote first."
    return
  fi

  log "Fetching list of sites from Dropbox: ${DROPBOX_REMOTE}"
  mapfile -t DOMAINS < <(rclone lsd "$DROPBOX_REMOTE" 2>/dev/null | awk '{print $5}' | sort)
  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    warn "No site folders found in Dropbox under wp-backups."
    return
  fi

  echo
  echo "Available backup sites from Dropbox:"
  local i=1
  for d in "${DOMAINS[@]}"; do
    echo "  [$i] $d"
    ((i++))
  done
  echo

  local sel
  while :; do
    read -rp "Select a site to restore [1-${#DOMAINS[@]}]: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] || { warn "Please enter a number."; continue; }
    (( sel >= 1 && sel <= ${#DOMAINS[@]} )) || { warn "Out of range."; continue; }
    break
  done

  local domain="${DOMAINS[sel-1]}"
  local LOCAL_RESTORE_DIR="/root/wp-restore/${domain}"
  mkdir -p "$LOCAL_RESTORE_DIR"

  echo
  log "Syncing latest backups for $domain from Dropbox..."
  rclone sync "${DROPBOX_REMOTE}/${domain}" "$LOCAL_RESTORE_DIR" || {
    err "rclone sync failed; cannot proceed."
    return
  }

  local latest_db latest_files
  latest_db="$(ls -1t "${LOCAL_RESTORE_DIR}/${domain}-db-"*.sql.gz 2>/dev/null | head -n1 || true)"
  latest_files="$(ls -1t "${LOCAL_RESTORE_DIR}/${domain}-files-"*.tar.gz 2>/dev/null | head -n1 || true)"

  if [[ -z "$latest_db" || -z "$latest_files" ]]; then
    err "Could not find DB and files backups for $domain in $LOCAL_RESTORE_DIR"
    return
  fi

  log "Using DB backup   : $latest_db"
  log "Using FILES backup: $latest_files"

  # Extract wp-config from files backup to get DB creds
  local TMP_DIR="/tmp/wp-restore-${domain}-$$"
  mkdir -p "$TMP_DIR"
  if ! tar -xzf "$latest_files" -C "$TMP_DIR"; then
    err "Failed to extract files archive."
    rm -rf "$TMP_DIR"
    return
  fi

  local config
  config="$(find "$TMP_DIR" -maxdepth 4 -name 'wp-config.php' | head -n1 || true)"
  if [[ -z "$config" ]]; then
    err "Could not find wp-config.php inside files archive."
    rm -rf "$TMP_DIR"
    return
  fi

  local DB_NAME DB_USER DB_PASS
  DB_NAME="$(grep -E "define\(\s*'DB_NAME'" "$config" | awk -F"'" '{print $4}')"
  DB_USER="$(grep -E "define\(\s*'DB_USER'" "$config" | awk -F"'" '{print $4}')"
  DB_PASS="$(grep -E "define\(\s*'DB_PASSWORD'" "$config" | awk -F"'" '{print $4}')"

  if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
    err "Could not parse DB_NAME/DB_USER/DB_PASSWORD from wp-config.php"
    rm -rf "$TMP_DIR"
    return
  fi

  log "Parsed DB credentials from backup:"
  echo "  DB_NAME: $DB_NAME"
  echo "  DB_USER: $DB_USER"
  echo "  DB_PASS: (hidden)"
  echo

  read -rp "Proceed with RESTORE for $domain (this may overwrite existing site)? (y/N): " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { warn "Restore cancelled."; rm -rf "$TMP_DIR"; return; }

  # Create DB and user
  log "Creating database and user (if not exist)..."
  mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || warn "Failed to create DB (might already exist)."
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" || warn "Failed to create user (might already exist)."
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" || warn "Failed to grant privileges (might already exist)."

  log "Importing database from $latest_db ..."
  if ! zcat "$latest_db" | mysql "$DB_NAME"; then
    err "Database import failed."
    rm -rf "$TMP_DIR"
    return
  fi

  # Deploy files to /home/<domain>/public_html
  local TARGET_ROOT="/home/${domain}/public_html"
  mkdir -p "$TARGET_ROOT"

  # Find extracted WP root (dir containing wp-config.php)
  local WP_EXTRACT_ROOT
  WP_EXTRACT_ROOT="$(dirname "$config")"

  log "Syncing WordPress files into $TARGET_ROOT ..."
  rsync -a --delete "$WP_EXTRACT_ROOT"/ "$TARGET_ROOT"/ || warn "rsync encountered issues."

  # Fix ownership if target already exists with a specific owner
  local owner group
  if [[ -e "$TARGET_ROOT" ]]; then
    owner="$(stat -c '%U' "$TARGET_ROOT" 2>/dev/null || echo root)"
    group="$(stat -c '%G' "$TARGET_ROOT" 2>/dev/null || echo root)"
    log "Applying chown -R ${owner}:${group} to ${TARGET_ROOT}"
    chown -R "${owner}:${group}" "$TARGET_ROOT" 2>/dev/null || true
  fi

  # Basic perms
  log "Applying basic permissions..."
  find "$TARGET_ROOT" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$TARGET_ROOT" -type f -exec chmod 644 {} \; 2>/dev/null || true
  [[ -f "$TARGET_ROOT/wp-config.php" ]] && chmod 600 "$TARGET_ROOT/wp-config.php" 2>/dev/null || true

  rm -rf "$TMP_DIR"

  echo
  log "Restore completed for $domain."
  echo "Please test the site in browser and update DNS/virtual host if needed."
}

# ------------------------ MIGRATION WIZARD (Option 7) ----------------------
migration_wizard() {
  echo
  echo "Select migration mode:"
  echo "  1) Old Server: Push sites from THIS server to another server (via Dropbox backups)"
  echo "  2) New Server: Pull sites from another server to THIS server (restore from Dropbox)"
  echo

  local choice
  while :; do
    read -rp "Choose [1-2]: " choice
    case "$choice" in
      1)
        log "Old Server mode selected."
        echo "This will:"
        echo "  - Create DAILY backups (DB + files) for all sites on THIS server."
        echo "  - Sync them to Dropbox: ${DROPBOX_REMOTE}"
        echo
        read -rp "Proceed with backup + Dropbox sync now? (y/N): " ok
        [[ "$ok" =~ ^[Yy]$ ]] || { warn "Cancelled."; return; }
        run_auto_backup_to_dropbox
        log "On the NEW server, run this same wp-tools script and choose:"
        log "  [7] WordPress migration wizard -> New Server mode"
        return
        ;;
      2)
        log "New Server mode selected."
        echo "This will:"
        echo "  - Read site backups from Dropbox: ${DROPBOX_REMOTE}"
        echo "  - Restore a selected site (DB + files) to THIS server."
        echo
        restore_wordpress_from_dropbox
        return
        ;;
      *)
        warn "Invalid choice. Please enter 1 or 2."
        ;;
    esac
  done
}

# ------------------------ FIX WORDPRESS PERMISSIONS -----------------------
fix_wp_permissions() {
  discover_wp_paths
  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found under /home."
    return
  fi

  echo
  log "Detected WordPress installs:"
  local i=1
  for wp in "${WP_PATHS[@]}"; do
    local domain
    domain="$(basename "$(dirname "$wp")")"
    echo "  [$i] ${domain} (${wp})"
    ((i++))
  done
  echo "  [A] All sites"
  echo

  read -rp "Fix permissions for which site? (number or A for all): " sel

  if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#WP_PATHS[@]} )); then
    local wp="${WP_PATHS[sel-1]}"
    local domain
    domain="$(basename "$(dirname "$wp")")"
    log "Fixing permissions for: $domain ($wp)"
    local owner group
    owner="$(stat -c '%U' "$wp/wp-config.php" 2>/dev/null || echo root)"
    group="$(stat -c '%G' "$wp/wp-config.php" 2>/dev/null || echo root)"
    log "Detected owner: ${owner}:${group}"

    chown -R "${owner}:${group}" "$wp" 2>/dev/null || true
    find "$wp" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$wp" -type f -exec chmod 644 {} \; 2>/dev/null || true
    [[ -f "$wp/wp-config.php" ]] && chmod 600 "$wp/wp-config.php" 2>/dev/null || true

    log "Permissions fixed for $domain."
  elif [[ "$sel" == "A" || "$sel" == "a" ]]; then
    for wp in "${WP_PATHS[@]}"; do
      local domain
      domain="$(basename "$(dirname "$wp")")"
      log "Fixing permissions for: $domain ($wp)"
      local owner group
      owner="$(stat -c '%U' "$wp/wp-config.php" 2>/dev/null || echo root)"
      group="$(stat -c '%G' "$wp/wp-config.php" 2>/dev/null || echo root)"
      chown -R "${owner}:${group}" "$wp" 2>/dev/null || true
      find "$wp" -type d -exec chmod 755 {} \; 2>/dev/null || true
      find "$wp" -type f -exec chmod 644 {} \; 2>/dev/null || true
      [[ -f "$wp/wp-config.php" ]] && chmod 600 "$wp/wp-config.php" 2>/dev/null || true
    done
    log "Permissions fixed for all WordPress sites."
  else
    warn "Invalid selection; no changes made."
  fi
}

# ------------------------ WORDPRESS HEALTH AUDIT --------------------------
health_audit() {
  discover_wp_paths
  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found under /home."
    return
  fi

  echo
  log "Running basic health audit for WordPress sites..."

  for wp in "${WP_PATHS[@]}"; do
    local domain
    domain="$(basename "$(dirname "$wp")")"
    echo
    echo "==============================="
    echo " Health report for: $domain"
    echo " Path: $wp"
    echo "==============================="

    # Owner
    local owner group
    owner="$(stat -c '%U' "$wp" 2>/dev/null || echo 'unknown')"
    group="$(stat -c '%G' "$wp" 2>/dev/null || echo 'unknown')"
    echo "Owner/Group: ${owner}:${group}"

    # Disk usage
    local du
    du="$(du -sh "$wp" 2>/dev/null | awk '{print $1}')"
    echo "Disk usage: ${du:-unknown}"

    # Check core
    [[ -f "$wp/wp-admin/index.php" ]] && echo "Core: wp-admin present" || echo "Core: MISSING wp-admin/index.php"
    [[ -f "$wp/wp-includes/version.php" ]] && echo "Core: wp-includes/version.php present" || echo "Core: MISSING wp-includes/version.php"

    # Uploads writable
    local uploads="${wp}/wp-content/uploads"
    if [[ -d "$uploads" ]]; then
      if sudo -u "$owner" test -w "$uploads" 2>/dev/null; then
        echo "Uploads: writable"
      else
        echo "Uploads: NOT writable as user $owner"
      fi
    else
      echo "Uploads: directory missing ($uploads)"
    fi

    # World-writable files
    local ww_count
    ww_count="$(find "$wp" -type f -perm -0002 2>/dev/null | wc -l)"
    echo "World-writable files: $ww_count"

    # Suspicious PHP files (very simple heuristic)
    local sus_count
    sus_count="$(grep -Rsl --exclude-dir=wp-includes --exclude-dir=wp-admin -E "eval\(|base64_decode\(" "$wp" 2>/dev/null | wc -l)"
    echo "Suspicious PHP files (eval/base64_decode): $sus_count (manual review recommended if > 0)"

    echo
  done

  log "Health audit completed."
}

# ----------------------------- MAIN MENU ----------------------------------
main_menu() {
  while :; do
    echo
    echo "==============================="
    echo "  WordPress Maintenance Tools"
    echo "==============================="
    echo "  [1] DB cleanup (WooCommerce order pruning)"
    echo "  [2] Malware scan (Maldet + ClamAV)"
    echo "  [3] Backup ALL MySQL/MariaDB databases"
    echo "  [4] Backup ONLY WordPress sites (DB + files)"
    echo "  [5] Exit"
    echo "  [6] Restore WordPress from Dropbox (DB + files)"
    echo "  [7] WordPress migration wizard (Old/New server via Dropbox)"
    echo "  [8] Auto Backups to Dropbox (run now + install daily cron)"
    echo "  [9] Fix WordPress file permissions"
    echo "  [10] WordPress health audit"
    echo

    read -rp "Select an option [1-10]: " CHOICE
    case "$CHOICE" in
      1) run_cleanup_script ;;
      2) run_malware_scan ;;
      3) backup_all_databases ;;
      4) backup_wp_databases ;;
      5) log "Goodbye."; exit 0 ;;
      6) restore_wordpress_from_dropbox ;;
      7) migration_wizard ;;
      8) auto_backups_to_dropbox ;;
      9) fix_wp_permissions ;;
      10) health_audit ;;
      *) warn "Invalid choice. Please enter a number between 1 and 10." ;;
    esac
  done
}

main() {
  # Special non-interactive mode for cron
  if [[ "${1-}" == "--auto-backup-to-dropbox" ]]; then
    require_root
    auto_install_requirements
    run_auto_backup_to_dropbox
    exit 0
  fi

  require_root
  auto_install_requirements
  main_menu
}

main "$@"
