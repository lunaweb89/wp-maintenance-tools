#!/usr/bin/env bash
#
# wp-tools.sh
#
# Master menu for WordPress maintenance tools:
#   1) DB cleanup (WooCommerce order pruning, indexing, etc.)
#   2) Malware scan (Maldet + ClamAV)
#   3) Backup ALL MySQL/MariaDB databases (mysqldump + gzip)
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

  # Ensure mysqldump exists
  if ! check_command "mysqldump" "mariadb-client or mysql-client"; then
    return 1
  fi

  # Default backup directory
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

  # Use /root/.my.cnf if it exists; otherwise, mysqldump will prompt.
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
    echo "  [4] Exit"
    echo

    read -rp "Select an option [1-4]: " CHOICE
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
        log "Goodbye."
        exit 0
        ;;
      *)
        warn "Invalid choice. Please enter 1, 2, 3, or 4."
        ;;
    esac
  done
}

main() {
  require_root
  main_menu
}

main "$@"
