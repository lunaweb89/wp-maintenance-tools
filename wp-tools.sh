#!/usr/bin/env bash
#
# wp-tools.sh
#
# Master menu for WordPress maintenance tools:
#   1) DB cleanup (WooCommerce order pruning, indexing, etc.)
#   2) Malware scan (Maldet + ClamAV)
#   3) Backup ALL MySQL/MariaDB databases (mysqldump + gzip)
#   4) Backup ONLY databases used by detected WordPress installs
#   5) Exit
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

log() {
  echo -e "${COLOR_BLUE}[+]${COLOR_RESET} $*"
}

warn() {
  echo -e "${COLOR_YELLOW}[-]${COLOR_RESET} $*"
}

err() {
  echo -e "${COLOR_RED}[!] $*${COLOR_RESET}" >&2
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root (e.g. sudo bash ...)."
    exit 1
  fi
}

check_command() {
  local cmd="$1"
  local pkg="${2:-}"
  if ! command -v "$cmd" &>/dev/null; then
    if [[ -n "$pkg" ]]; then
      err "Required command '$cmd' not found. Please install package: $pkg"
    else
      err "Required command '$cmd' not found. Please install it and try again."
    fi
    return 1
  fi
  return 0
}

backup_all_databases() {
  log "MySQL/MariaDB full backup selected."

  if ! check_command "mysqldump" "mariadb-client or mysql-client"; then
    return 1
  fi

  local BACKUP_DIR="/root/mysql-backups"
  mkdir -p "$BACKUP_DIR"

  local TS
  TS="$(date +%Y%m%d-%H%M%S)"
  local BACKUP_FILE="${BACKUP_DIR}/all-databases-${TS}.sql.gz"

  echo
  log "Backup details:"
  echo "  Directory : ${BACKUP_DIR}"
  echo "  File      : ${BACKUP_FILE}"
  echo
  echo "Notes:"
  echo "  - This uses: mysqldump --all-databases | gzip"
  echo "  - If /root/.my.cnf has user/password, no prompt is needed."
  echo "  - Otherwise, you'll be prompted for the MySQL root password."
  echo

  read -rp "Proceed with full DB backup? (y/N): " CONFIRM
  case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *)
      warn "Backup cancelled."
      return 0
      ;;
  esac

  log "Starting full database backup (this may take a while)..."

  if [[ -f /root/.my.cnf ]]; then
    if mysqldump --all-databases | gzip > "$BACKUP_FILE"; then
      log "Backup completed successfully."
      log "Backup file: ${BACKUP_FILE}"
    else
      err "Backup failed. Please check MySQL credentials and available disk space."
      [[ -f "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"
      return 1
    fi
  else
    warn "/root/.my.cnf not found. You may be prompted for MySQL root password."
    if mysqldump -u root -p --all-databases | gzip > "$BACKUP_FILE"; then
      log "Backup completed successfully."
      log "Backup file: ${BACKUP_FILE}"
    else
      err "Backup failed. Please check password / MySQL status."
      [[ -f "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"
      return 1
    fi
  fi

  return 0
}

# Option 4: backup ONLY DBs used by detected WordPress installs
backup_wp_databases() {
  log "WordPress-only database backup selected."

  if ! check_command "mysqldump" "mariadb-client or mysql-client"; then
    return 1
  fi

  log "Scanning for WordPress installations under /home..."
  # Find wp-config.php under /home/*/public_html and strip the filename
  mapfile -t WP_PATHS < <(find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null | sed 's#/wp-config.php$##' | sort)

  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found under /home."
    return 0
  fi

  declare -a WP_SITES=()
  declare -a WP_DBS=()

  echo
  log "Detected WordPress installations:"
  local idx=1
  for wp_path in "${WP_PATHS[@]}"; do
    local user_dir domain config db_name
    user_dir="$(dirname "$wp_path")"           # /home/domain
    domain="$(basename "$user_dir")"           # domain
    config="${wp_path}/wp-config.php"

    db_name="$(grep -E "define\(\s*'DB_NAME'" "$config" 2>/dev/null | head -n1 | awk -F"'" '{print $4}')"

    if [[ -z "$db_name" ]]; then
      warn "Could not parse DB_NAME from ${config}, skipping."
      continue
    fi

    echo "  [$idx] ${domain}  (path: ${wp_path}, DB: ${db_name})"
    WP_SITES+=("${domain}")
    WP_DBS+=("${db_name}")
    ((idx++))
  done

  if [[ ${#WP_DBS[@]} -eq 0 ]]; then
    err "No valid DB_NAME values detected from wp-config.php files."
    return 1
  fi

  # Build unique DB list
  declare -A UNIQUE_DBS=()
  for db in "${WP_DBS[@]}"; do
    UNIQUE_DBS["$db"]=1
  done

  echo
  log "Unique databases that will be backed up:"
  for db in "${!UNIQUE_DBS[@]}"; do
    echo "  - ${db}"
  done

  echo
  read -rp "Proceed with backup of these WordPress databases only? (y/N): " CONFIRM
  case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *)
      warn "Backup cancelled."
      return 0
      ;;
  esac

  local BACKUP_DIR="/root/mysql-backups"
  mkdir -p "$BACKUP_DIR"
  local TS
  TS="$(date +%Y%m%d-%H%M%S)"

  log "Starting per-database backups into ${BACKUP_DIR}..."

  # Helper: dump a single DB
  backup_one_db() {
    local dbname="$1"
    local outfile="${BACKUP_DIR}/${dbname}-${TS}.sql.gz"

    log "Backing up DB '${dbname}' -> ${outfile}"

    if [[ -f /root/.my.cnf ]]; then
      if mysqldump "${dbname}" | gzip > "$outfile"; then
        log "  OK: ${dbname}"
      else
        err "  FAILED: ${dbname}"
        [[ -f "$outfile" ]] && rm -f "$outfile"
        return 1
      fi
    else
      warn "/root/.my.cnf not found. You may be prompted for MySQL root password for '${dbname}'."
      if mysqldump -u root -p "${dbname}" | gzip > "$outfile"; then
        log "  OK: ${dbname}"
      else
        err "  FAILED: ${dbname}"
        [[ -f "$outfile" ]] && rm -f "$outfile"
        return 1
      fi
    fi
    return 0
  }

  local failures=0
  for db in "${!UNIQUE_DBS[@]}"; do
    if ! backup_one_db "$db"; then
      ((failures++))
    fi
  done

  echo
  if [[ $failures -eq 0 ]]; then
    log "All WordPress databases backed up successfully."
  else
    err "$failures database(s) failed to back up. Check logs above."
  fi

  return 0
}

run_cleanup_script() {
  log "Launching DB cleanup tool (cleanup-script.sh)..."
  bash <(curl -fsSL "${REPO_BASE}/cleanup-script.sh")
}

run_malware_scan() {
  log "Launching malware scan tool (wp-malware-scan.sh)..."
  bash <(curl -fsSL "${REPO_BASE}/wp-malware-scan.sh")
}

main_menu() {
  while :; do
    echo
    echo "==============================="
    echo "  WordPress Maintenance Tools"
    echo "==============================="
    echo "  [1] DB cleanup (WooCommerce order pruning)"
    echo "  [2] Malware scan (Maldet + ClamAV)"
    echo "  [3] Backup ALL MySQL/MariaDB databases"
    echo "  [4] Backup ONLY WordPress databases (detected installs)"
    echo "  [5] Exit"
    echo

    read -rp "Select an option [1-5]: " CHOICE
    case "$CHOICE" in
      1)
        run_cleanup_script
        ;;
      2)
        run_malware_scan
        ;;
      3)
        backup_all_databases
        ;;
      4)
        backup_wp_databases
        ;;
      5)
        log "Goodbye."
        exit 0
        ;;
      *)
        warn "Invalid choice. Please enter 1, 2, 3, 4, or 5."
        ;;
    esac
  done
}

main() {
  require_root
  main_menu
}

main "$@"
