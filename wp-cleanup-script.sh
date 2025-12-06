#!/usr/bin/env bash
#
# wp-cleanup-script.sh
#
# WordPress + WooCommerce DB cleanup tool.
#
# - Auto-detects WordPress installs under /home/*/public_html
# - Asks which site to clean
# - Prompts how many YEARS of WooCommerce order history to keep
# - Creates a full DB backup via WP-CLI (wp db export) BEFORE any delete
# - Deletes old WooCommerce orders, order meta, notes, analytics rows
# - Optionally trims old AutomateWoo logs (if tables exist)
# - Optimizes the heaviest tables afterwards
# - If ANY cleanup step fails, backup is kept; only deleted on clean success
#
# Run (as root) directly from GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-cleanup-script.sh)
#

set -uo pipefail

# ---------- Colors & helpers ----------
COLOR_RED="$(tput setaf 1 2>/dev/null || echo "")"
COLOR_GREEN="$(tput setaf 2 2>/dev/null || echo "")"
COLOR_YELLOW="$(tput setaf 3 2>/dev/null || echo "")"
COLOR_BLUE="$(tput setaf 4 2>/dev/null || echo "")"
COLOR_RESET="$(tput sgr0 2>/dev/null || echo "")"

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

# ---------- Environment checks ----------

check_php_mysqli() {
  if php -m 2>/dev/null | grep -qi mysqli; then
    log "OK: PHP mysqli extension is already enabled for CLI."
    return 0
  fi

  warn "PHP mysqli extension is missing. Attempting to install automatically..."
  if command -v apt-get &>/dev/null; then
    log "Detected Debian/Ubuntu (apt). Installing php-mysql..."
    apt-get update -y || {
      err "apt-get update failed. Please fix APT/DPKG issues and rerun."
      exit 1
    }
    apt-get install -y php-mysql || {
      err "Failed to install php-mysql. Please install/enable mysqli manually, then rerun."
      exit 1
    }
  elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
    PKG_MGR=$(command -v dnf || command -v yum)
    log "Detected RHEL/CentOS/Alma/Rocky (${PKG_MGR}). Installing php-mysqlnd..."
    "$PKG_MGR" install -y php-mysqlnd || {
      err "Failed to install php-mysqlnd. Please install/enable mysqli manually, then rerun."
      exit 1
    }
  else
    err "Unknown package manager. Please install PHP mysqli extension manually."
    exit 1
  fi

  if php -m 2>/dev/null | grep -qi mysqli; then
    log "OK: PHP mysqli extension is now enabled for CLI."
  else
    err "mysqli extension still not detected after attempted install. Please fix manually."
    exit 1
  fi
}

check_wp_cli() {
  if command -v wp &>/dev/null; then
    log "OK: WP-CLI is available."
  else
    err "WP-CLI is not installed. Please install WP-CLI and rerun."
    echo "    See: https://wp-cli.org/"
    exit 1
  fi
}

# ---------- WordPress detection ----------

discover_wp_installs() {
  local installs=()
  while IFS= read -r cfg; do
    installs+=("$cfg")
  done < <(find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null | sort)

  if ((${#installs[@]} == 0)); then
    err "No WordPress installations found under /home/*/public_html."
    exit 1
  fi

  log "Scanning for WordPress installations under /home/*/public_html..."
  echo
  echo "Found the following WordPress installs:"
  local i=1
  for cfg in "${installs[@]}"; do
    local base path domain
    path="$(dirname "$cfg")"
    base="$(basename "$(dirname "$path")")"  # e.g. domain.com from /home/domain.com/public_html
    domain="$base"
    echo "  [$i] ${domain}  (${path})"
    ((i++))
  done
  echo

  local choice
  while :; do
    read -rp "Select site number to clean: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Please enter a number."; continue; }
    if (( choice < 1 || choice > ${#installs[@]} )); then
      warn "Invalid choice. Choose between 1 and ${#installs[@]}."
      continue
    fi
    break
  done

  WP_PATH="$(dirname "${installs[choice-1]}")"
  WP_PARENT="$(dirname "$WP_PATH")"
  DOMAIN="$(basename "$WP_PARENT")"

  echo
  log "Selected site:"
  echo "  Domain: ${DOMAIN}"
  echo "  Path  : ${WP_PATH}"
  echo

  # Figure out owning user of wp-config.php
  WP_USER="$(stat -c '%U' "$WP_PATH/wp-config.php" 2>/dev/null || echo "www-data")"
  if [[ -z "$WP_USER" || "$WP_USER" == "root" ]]; then
    WP_USER="www-data"
  fi
}

# helper: run WP-CLI as the site user
wp_site() {
  sudo -u "$WP_USER" -i -- wp "$@" --path="$WP_PATH"
}

# DB query wrapper
wp_db_query() {
  local sql="$1"
  wp_site db query "$sql"
}

wp_db_query_nonfatal() {
  local sql="$1"
  if ! wp_db_query "$sql"; then
    ERRORS=1
    warn "Query failed (non-fatal): $sql"
  fi
}

table_exists() {
  local tbl="$1"
  local out
  out="$(wp_db_query "SHOW TABLES LIKE '${tbl}';" --skip-column-names 2>/dev/null || true)"
  [[ "$out" == "$tbl" ]]
}

# ---------- Main logic ----------

main() {
  require_root
  check_php_mysqli
  check_wp_cli
  discover_wp_installs

  log "Detecting DB table prefix via WP-CLI..."
  DB_PREFIX="$(wp_site db prefix --skip-column-names 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$DB_PREFIX" ]]; then
    err "Could not detect DB prefix via WP-CLI."
    exit 1
  fi
  log "Detected table prefix: ${DB_PREFIX}"

  # Ask how many years of history to keep
  echo
  read -rp "How many YEARS of WooCommerce order history do you want to KEEP? [default: 3] " YEARS
  if [[ -z "$YEARS" ]]; then
    YEARS=3
  fi
  if ! [[ "$YEARS" =~ ^[0-9]+$ ]] || (( YEARS < 1 || YEARS > 10 )); then
    err "Invalid number of years: $YEARS (must be between 1 and 10)."
    exit 1
  fi
  log "Keeping last ${YEARS} year(s) of orders; anything older will be eligible for deletion."
  echo

  # Backup DB via WP-CLI
  BACKUP_DIR="/root/wp-db-backups"
  mkdir -p "$BACKUP_DIR"
  TS="$(date +%Y%m%d-%H%M%S)"
  BACKUP_FILE="${BACKUP_DIR}/${DOMAIN}-db-backup-before-cleanup-${TS}.sql"

  log "Creating database backup with WP-CLI (wp db export)..."
  if wp_site db export "$BACKUP_FILE"; then
    log "Backup created: ${BACKUP_FILE}"
  else
    err "Backup failed; aborting cleanup. No data has been deleted."
    exit 1
  fi

  # Show current DB size
  echo
  log "Checking current DB size..."
  wp_site db size --all-tables

  # Helper table name (prefix-aware)
  HELPER_TABLE="${DB_PREFIX}old_orders_cleanup"

  ERRORS=0

  echo
  log "Ensuring helper table ${HELPER_TABLE} exists..."
  wp_db_query_nonfatal "CREATE TABLE IF NOT EXISTS ${HELPER_TABLE} (order_id BIGINT(20) UNSIGNED PRIMARY KEY) ENGINE=InnoDB;"

  log "Filling helper table with orders older than ${YEARS} year(s)..."
  wp_db_query_nonfatal "TRUNCATE TABLE ${HELPER_TABLE};"
  wp_db_query_nonfatal "
    INSERT IGNORE INTO ${HELPER_TABLE} (order_id)
    SELECT ID
    FROM ${DB_PREFIX}posts
    WHERE post_type = 'shop_order'
      AND post_date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);
  "

  echo
  log "Counts BEFORE deletion (older than ${YEARS} year(s)):"
  wp_db_query "SELECT COUNT(*) AS old_orders FROM ${DB_PREFIX}posts WHERE post_type='shop_order' AND post_date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);"
  wp_db_query "SELECT COUNT(*) AS old_order_items FROM ${DB_PREFIX}woocommerce_order_items oi JOIN ${DB_PREFIX}posts p ON oi.order_id = p.ID WHERE p.post_type='shop_order' AND p.post_date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);"
  wp_db_query "SELECT COUNT(*) AS old_order_itemmeta FROM ${DB_PREFIX}woocommerce_order_itemmeta oim JOIN ${DB_PREFIX}woocommerce_order_items oi ON oi.order_item_id = oim.order_item_id JOIN ${DB_PREFIX}posts p ON oi.order_id = p.ID WHERE p.post_type='shop_order' AND p.post_date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);"
  wp_db_query "SELECT COUNT(*) AS old_comments FROM ${DB_PREFIX}comments c JOIN ${DB_PREFIX}posts p ON p.ID = c.comment_post_ID WHERE p.post_type='shop_order' AND p.post_date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);"

  if table_exists "${DB_PREFIX}automatewoo_logs"; then
    wp_db_query "SELECT COUNT(*) AS aw_logs_old FROM ${DB_PREFIX}automatewoo_logs WHERE date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);"
  else
    log "AutomateWoo logs table not found; skipping AutomateWoo-specific cleanup."
  fi

  echo
  read -rp "Proceed with deletion of data older than ${YEARS} year(s)? (y/N): " CONFIRM
  case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *)
      warn "Aborting cleanup. Backup kept at: ${BACKUP_FILE}"
      exit 0
      ;;
  esac

  echo
  # ---- Deletions start here ----

  if table_exists "${DB_PREFIX}automatewoo_logs"; then
    log "Deleting old AutomateWoo log meta..."
    wp_db_query_nonfatal "
      DELETE lm
      FROM ${DB_PREFIX}automatewoo_log_meta lm
      JOIN ${DB_PREFIX}automatewoo_logs l ON lm.log_id = l.id
      WHERE l.date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);
    "

    log "Deleting old AutomateWoo logs..."
    wp_db_query_nonfatal "
      DELETE
      FROM ${DB_PREFIX}automatewoo_logs
      WHERE date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);
    "
  fi

  log "Deleting old WooCommerce comments (order notes)..."
  wp_db_query_nonfatal "
    DELETE c
    FROM ${DB_PREFIX}comments c
    JOIN ${DB_PREFIX}posts p ON p.ID = c.comment_post_ID
    JOIN ${HELPER_TABLE} h ON h.order_id = p.ID;
  "

  log "Deleting old WooCommerce order itemmeta..."
  wp_db_query_nonfatal "
    DELETE oim
    FROM ${DB_PREFIX}woocommerce_order_itemmeta oim
    JOIN ${DB_PREFIX}woocommerce_order_items oi ON oi.order_item_id = oim.order_item_id
    JOIN ${HELPER_TABLE} h ON h.order_id = oi.order_id;
  "

  log "Deleting old WooCommerce order items..."
  wp_db_query_nonfatal "
    DELETE oi
    FROM ${DB_PREFIX}woocommerce_order_items oi
    JOIN ${HELPER_TABLE} h ON h.order_id = oi.order_id;
  "

  log "Deleting old orders from posts + postmeta..."
  wp_db_query_nonfatal "
    DELETE pm
    FROM ${DB_PREFIX}postmeta pm
    JOIN ${HELPER_TABLE} h ON h.order_id = pm.post_id;
  "
  wp_db_query_nonfatal "
    DELETE p
    FROM ${DB_PREFIX}posts p
    JOIN ${HELPER_TABLE} h ON h.order_id = p.ID;
  "

  log "Cleaning WooCommerce analytics / lookup tables..."
  if table_exists "${DB_PREFIX}wc_order_stats"; then
    wp_db_query_nonfatal "
      DELETE s
      FROM ${DB_PREFIX}wc_order_stats s
      JOIN ${HELPER_TABLE} h ON h.order_id = s.order_id;
    "
  fi

  if table_exists "${DB_PREFIX}wc_order_product_lookup"; then
    wp_db_query_nonfatal "
      DELETE l
      FROM ${DB_PREFIX}wc_order_product_lookup l
      JOIN ${HELPER_TABLE} h ON h.order_id = l.order_id;
    "
  fi

  if table_exists "${DB_PREFIX}wc_order_tax_lookup"; then
    wp_db_query_nonfatal "
      DELETE t
      FROM ${DB_PREFIX}wc_order_tax_lookup t
      JOIN ${HELPER_TABLE} h ON h.order_id = t.order_id;
    "
  fi

  if table_exists "${DB_PREFIX}wc_order_coupon_lookup"; then
    wp_db_query_nonfatal "
      DELETE c
      FROM ${DB_PREFIX}wc_order_coupon_lookup c
      JOIN ${HELPER_TABLE} h ON h.order_id = c.order_id;
    "
  fi

  log "Dropping helper table ${HELPER_TABLE}..."
  wp_db_query_nonfatal "DROP TABLE IF EXISTS ${HELPER_TABLE};"

  echo
  log "Optimizing largest WooCommerce-related tables..."
  wp_db_query_nonfatal "
    OPTIMIZE TABLE
      ${DB_PREFIX}postmeta,
      ${DB_PREFIX}posts,
      ${DB_PREFIX}comments,
      ${DB_PREFIX}woocommerce_order_items,
      ${DB_PREFIX}woocommerce_order_itemmeta,
      ${DB_PREFIX}wc_order_stats,
      ${DB_PREFIX}wc_order_product_lookup;
  "

  echo
  log "Final DB size after cleanup:"
  wp_site db size --all-tables

  echo
  if (( ERRORS == 0 )); then
    log "Cleanup completed successfully with no query errors."
    log "Removing backup: ${BACKUP_FILE}"
    rm -f "$BACKUP_FILE" || warn "Could not delete backup; please remove manually if not needed."
  else
    warn "Some operations had errors. Backup has been KEPT at:"
    echo "  ${BACKUP_FILE}"
  fi

  echo
  log "Done."
}

main "$@"
