#!/usr/bin/env bash
#
# wp-toolkit.sh
#
# Master menu for WordPress maintenance tools:
#
#   [1] DB cleanup (WooCommerce order pruning)
#   [2] Run Malware scan (Maldet + ClamAV)
#   [3] Backup WordPress sites (local migration backups)
#   [4] Backup ONLY WordPress sites to Dropbox (DB + files)
#   [5] Restore WordPress from Dropbox (DB + files)
#   [6] Run WordPress migration wizard (local backups, server to server)
#   [7] Run Auto Backups Wizard to Dropbox (run now + install daily cron)
#   [8] Check & Fix WordPress file permissions
#   [9] Run WordPress health audit
#   [10] Exit
#
# Run directly from GitHub (as root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh)
#

set -euo pipefail

COLOR_RED="$(tput setaf 1 2>/dev/null || echo "")"
COLOR_GREEN="$(tput setaf 2 2>/dev/null || echo "")"
COLOR_YELLOW="$(tput setaf 3 2>/dev/null || echo "")"
COLOR_BLUE="$(tput setaf 4 2>/dev/null || echo "")"
COLOR_RESET="$(tput sgr0 2>/dev/null || echo "")"

REPO_BASE="https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main"

log()  { echo -e "${COLOR_BLUE}[+]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[-]${COLOR_RESET} $*"; }
err()  { echo -e "${COLOR_RED}[!] $*${COLOR_RESET}" >&2; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root (sudo)."
    exit 1
  fi
}

check_core_tools() {
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required. Please install it: apt-get install -y curl"
    exit 1
  fi
}

run_cleanup_script() {
  log "Launching DB cleanup tool (cleanup-script.sh)..."
  bash <(curl -fsSL "${REPO_BASE}/cleanup-script.sh")
}

run_malware_scan() {
  log "Launching malware scan tool (wp-malware-scan.sh)..."
  bash <(curl -fsSL "${REPO_BASE}/wp-malware-scan.sh")
}

backup_wp_local_migration() {
  log "Running local migration-style backup for selected WordPress sites..."
  # --backup-only = Old server backup mode (with site selection)
  bash <(curl -fsSL "${REPO_BASE}/wp-migrate-local.sh") --backup-only
}

backup_wp_to_dropbox_manual() {
  log "Launching manual WP → Dropbox backup (DB + files, no local retention)..."
  bash <(curl -fsSL "${REPO_BASE}/wp-backup-dropbox.sh")
}

restore_from_dropbox() {
  log "Launching restore from Dropbox (DB + files)..."
  bash <(curl -fsSL "${REPO_BASE}/wp-restore-dropbox.sh")
}

migration_wizard_local() {
  log "Launching WordPress migration wizard (local backups, server to server)..."
  bash <(curl -fsSL "${REPO_BASE}/wp-migrate-local.sh")
}

auto_backups_to_dropbox() {
  log "Launching Auto Backups Wizard to Dropbox (run now + install daily cron)..."
  bash <(curl -fsSL "${REPO_BASE}/wp-backup-dropbox.sh") --auto-setup
}

fix_wp_permissions() {
  log "Launching WordPress permission fixer..."
  bash <(curl -fsSL "${REPO_BASE}/wp-fix-perms.sh")
}

health_audit() {
  log "Launching WordPress health audit..."
  bash <(curl -fsSL "${REPO_BASE}/wp-health-audit.sh")
}

main_menu() {
  while :; do
    echo
    echo "==============================="
    echo "  WordPress Maintenance Tools"
    echo "==============================="
    echo "  [1] DB cleanup (WooCommerce order pruning)"
    echo "  [2] Run Malware scan (Maldet + ClamAV)"
    echo "  [3] Backup WordPress sites (local migration backups)"
    echo "  [4] Backup ONLY WordPress sites to Dropbox (DB + files)"
    echo "  [5] Restore WordPress from Dropbox (DB + files)"
    echo "  [6] Run WordPress migration wizard (local backups, server to server)"
    echo "  [7] Run Auto Backups Wizard to Dropbox (run now + install daily cron)"
    echo "  [8] Check & Fix WordPress file permissions"
    echo "  [9] Run WordPress health audit"
    echo "  [10] Exit"
    echo

    read -rp "Select an option [1-10]: " CHOICE

    case "$CHOICE" in
      1) run_cleanup_script ;;
      2) run_malware_scan ;;
      3) backup_wp_local_migration ;;
      4) backup_wp_to_dropbox_manual ;;
      5) restore_from_dropbox ;;
      6) migration_wizard_local ;;
      7) auto_backups_to_dropbox ;;
      8) fix_wp_permissions ;;
      9) health_audit ;;
      10) log "Goodbye."; exit 0 ;;
      *) warn "Invalid choice. Please enter a number between 1 and 10." ;;
    esac
  done
}

main() {
  require_root
  check_core_tools
  main_menu
}

main "$@"
