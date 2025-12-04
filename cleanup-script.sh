#!/usr/bin/env bash
# WordPress DB cleanup & optimization script
# - Auto-checks PHP + mysqli + WP-CLI
# - Lists WordPress installs under /home/*/public_html
# - Cleans:
#     * wp_options bloat (transients, WC sessions, doing_cron)
#     * WooCommerce orders older than 3 years (if WooCommerce present)
# - Optimizes large Woo tables afterwards
#
# Run as root:
#   bash <(curl -s https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/cleanup-script.sh)

set -euo pipefail

########################
# Helper functions
########################

log() {
  echo -e "[$(date +'%F %T')] $*"
}

pause_if_error() {
  local rc=$1
  local msg="$2"
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: $msg"
    exit "$rc"
  fi
}

########################
# Requirement checks
########################

check_php_and_extensions() {
  if ! command -v php >/dev/null 2>&1; then
    echo "PHP CLI not found. Please install PHP (php-cli) and re-run this script."
    exit 1
  fi

  # Check mysqli
  if ! php -m | grep -qi 'mysqli'; then
    echo "PHP mysqli extension is missing. Attempting to install automatically..."
    if command -v apt-get >/dev/null 2>&1; then
      log "Detected Debian/Ubuntu (apt). Installing php-mysql..."
      apt-get update -y
      apt-get install -y php-mysql || {
        echo "ERROR: Unable to install php-mysql via apt-get. Install manually and re-run."
        exit 1
      }
    elif command -v yum >/dev/null 2>&1; then
      log "Detected RHEL/CentOS (yum). Installing php-mysqlnd..."
      yum install -y php-mysqlnd || {
        echo "ERROR: Unable to install php-mysqlnd via yum. Install manually and re-run."
        exit 1
      }
    elif command -v dnf >/dev/null 2>&1; then
      log "Detected RHEL/Fedora (dnf). Installing php-mysqlnd..."
      dnf install -y php-mysqlnd || {
        echo "ERROR: Unable to install php-mysqlnd via dnf. Install manually and re-run."
        exit 1
      }
    else
      echo "ERROR: Unknown package manager. Please install mysqli extension manually."
      exit 1
    fi

    if ! php -m | grep -qi 'mysqli'; then
      echo "ERROR: mysqli extension still not detected after attempted install."
      exit 1
    fi
  fi

  echo "OK: PHP mysqli extension is already enabled for CLI."
}

check_wp_cli() {
  if command -v wp >/dev/null 2>&1; then
    echo "OK: WP-CLI is available."
    return
  fi

  echo "WP-CLI not found. Attempting to install to /usr/local/bin/wp..."
  curl -s -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp

  if ! command -v wp >/dev/null 2>&1; then
    echo "ERROR: WP-CLI installation failed. Please install manually and re-run."
    exit 1
  fi

  echo "OK: WP-CLI installed."
}

########################
# Site discovery & selection
########################

discover_wp_installs() {
  WP_SITES=()
  WP_PATHS=()

  # Main CyberPanel-style paths
  for path in /home/*/public_html; do
    [ -d "$path" ] || continue
    if [ -f "$path/wp-config.php" ]; then
      domain="$(basename "$(dirname "$path")")"
      WP_SITES+=("$domain")
      WP_PATHS+=("$path")
    fi
  done
}

choose_site() {
  discover_wp_installs

  if [ "${#WP_SITES[@]}" -eq 0 ]; then
    echo "No WordPress installations found under /home/*/public_html."
    exit 1
  fi

  echo "Scanning for WordPress installations under /home/*/public_html..."
  echo
  echo "Found the following WordPress installs:"
  echo

  for i in "${!WP_SITES[@]}"; do
    printf "  [%d] %s  (%s)\n" "$((i+1))" "${WP_SITES[$i]}" "${WP_PATHS[$i]}"
  done

  echo
  read -rp "Select site number to clean: " choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#WP_SITES[@]}" ]; then
    echo "Invalid choice."
    exit 1
  fi

  INDEX=$((choice-1))
  SELECTED_DOMAIN="${WP_SITES[$INDEX]}"
  SELECTED_PATH="${WP_PATHS[$INDEX]}"

  echo
  echo "Selected site:"
  echo "  Domain: $SELECTED_DOMAIN"
  echo "  Path  : $SELECTED_PATH"
  echo
}

########################
# WordPress / WooCommerce details
########################

detect_table_prefix() {
  local path="$1"
  log "Detecting DB table prefix via WP-CLI..."
  DB_PREFIX="$(wp config get table_prefix --path="$path" --allow-root 2>/dev/null || echo 'wp_')"

  # Normalize, in case WP-CLI printed quotes
  DB_PREFIX="${DB_PREFIX//\"/}"
  DB_PREFIX="${DB_PREFIX//\'/}"

  echo "Detected table prefix: $DB_PREFIX"
}

has_woocommerce() {
  local path="$1"
  if wp plugin is-installed woocommerce --path="$path" --allow-root >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

########################
# wp_options cleanup (D)
########################

cleanup_wp_options() {
  local path="$1"
  local tp="$2"

  echo
  log "Starting wp_options cleanup (auto, no prompt)..."

  local before_rows
  before_rows="$(wp db query "SELECT COUNT(*) FROM ${tp}options;" --path="$path" --allow-root --skip-column-names 2>/dev/null || echo "0")"

  # 1. Expired / regular transients
  log " - Deleting transients (_transient_*, _site_transient_*)..."
  wp db query "DELETE FROM ${tp}options WHERE option_name LIKE '_transient_%' OR option_name LIKE '_site_transient_%';" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  # 2. WooCommerce sessions
  log " - Deleting WooCommerce sessions (_wc_session_*)..."
  wp db query "DELETE FROM ${tp}options WHERE option_name LIKE '_wc_session_%' OR option_name LIKE '_wc_session_expires_%';" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  # 3. Stuck cron flag
  log " - Removing stuck cron flag (doing_cron)..."
  wp db query "DELETE FROM ${tp}options WHERE option_name = 'doing_cron';" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  # Optionally, optimize options table
  log " - Optimizing ${tp}options table..."
  wp db query "OPTIMIZE TABLE ${tp}options;" --path="$path" --allow-root >/dev/null 2>&1 || true

  local after_rows
  after_rows="$(wp db query "SELECT COUNT(*) FROM ${tp}options;" --path="$path" --allow-root --skip-column-names 2>/dev/null || echo "0")"

  echo
  echo "wp_options rows before: $before_rows"
  echo "wp_options rows after : $after_rows"
  echo "wp_options cleanup complete."
  echo
}

########################
# WooCommerce 3-year cleanup
########################

woocommerce_cleanup_3y() {
  local path="$1"
  local tp="$2"

  if ! has_woocommerce "$path"; then
    echo "WooCommerce not detected on this site. Skipping 3-year order cleanup."
    return
  fi

  local helper="${tp}old_orders_3y"

  echo
  log "Ensuring helper table ${helper} exists..."
  wp db query "CREATE TABLE IF NOT EXISTS ${helper} (order_id BIGINT UNSIGNED PRIMARY KEY) ENGINE=InnoDB;" \
    --path="$path" --allow-root

  echo
  log "Filling helper table with orders older than 3 years..."
  wp db query "INSERT IGNORE INTO ${helper} (order_id)
                SELECT ID FROM ${tp}posts
                WHERE post_type = 'shop_order'
                  AND post_date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" \
    --path="$path" --allow-root

  echo
  log "Counts BEFORE deletion (older than 3 years):"
  wp db query "SELECT COUNT(*) AS old_orders
               FROM ${tp}posts
               WHERE ID IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root

  wp db query "SELECT COUNT(*) AS old_order_items
               FROM ${tp}woocommerce_order_items oi
               WHERE oi.order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root

  wp db query "SELECT COUNT(*) AS old_order_itemmeta
               FROM ${tp}woocommerce_order_itemmeta oim
               JOIN ${tp}woocommerce_order_items oi
                 ON oi.order_item_id = oim.order_item_id
               WHERE oi.order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root

  wp db query "SELECT COUNT(*) AS old_comments
               FROM ${tp}comments c
               JOIN ${tp}posts p ON p.ID = c.comment_post_ID
               WHERE p.ID IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root

  wp db query "SELECT COUNT(*) AS aw_logs_old
               FROM ${tp}automatewoo_logs l
               WHERE l.date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" \
    --path="$path" --allow-root || true

  echo
  read -rp "Proceed with deletion of data older than 3 years? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborting 3-year cleanup. No data was deleted."
    return
  fi

  echo
  log "Deleting old AutomateWoo log meta..."
  wp db query "DELETE FROM ${tp}automatewoo_log_meta
               WHERE log_id IN (
                 SELECT id FROM ${tp}automatewoo_logs
                 WHERE date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR)
               );" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  log "Deleting old AutomateWoo logs..."
  wp db query "DELETE FROM ${tp}automatewoo_logs
               WHERE date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  log "Deleting old WooCommerce comments (order notes)..."
  wp db query "DELETE c FROM ${tp}comments c
               JOIN ${tp}posts p ON p.ID = c.comment_post_ID
               WHERE p.ID IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  log "Deleting old WooCommerce order itemmeta..."
  wp db query "DELETE oim FROM ${tp}woocommerce_order_itemmeta oim
               JOIN ${tp}woocommerce_order_items oi
                 ON oi.order_item_id = oim.order_item_id
               WHERE oi.order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  log "Deleting old WooCommerce order items..."
  wp db query "DELETE FROM ${tp}woocommerce_order_items
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  log "Deleting old orders from posts + postmeta..."
  wp db query "DELETE FROM ${tp}postmeta
               WHERE post_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  wp db query "DELETE FROM ${tp}posts
               WHERE ID IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  echo
  log "Cleaning WooCommerce analytics / lookup tables..."
  wp db query "DELETE FROM ${tp}wc_order_product_lookup
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  wp db query "DELETE FROM ${tp}wc_order_stats
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  wp db query "DELETE FROM ${tp}wc_order_tax_lookup
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  wp db query "DELETE FROM ${tp}wc_order_coupon_lookup
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  wp db query "DELETE FROM ${tp}wc_order_addresses
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
    --path="$path" --allow-root >/dev/null 2>&1 || true

  echo
  log "Dropping helper table ${helper}..."
  wp db query "DROP TABLE IF EXISTS ${helper};" --path="$path" --allow-root >/dev/null 2>&1 || true

  echo
  log "Optimizing largest order-related tables..."
  wp db query "OPTIMIZE TABLE
                 ${tp}postmeta,
                 ${tp}posts,
                 ${tp}comments,
                 ${tp}woocommerce_order_items,
                 ${tp}woocommerce_order_itemmeta,
                 ${tp}wc_order_stats,
                 ${tp}wc_order_product_lookup;" \
    --path="$path" --allow-root || true

  echo
  log "Counts AFTER deletion (sanity check):"
  wp db query "SELECT COUNT(*) AS old_orders
               FROM ${tp}posts
               WHERE post_type = 'shop_order'
                 AND post_date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" \
    --path="$path" --allow-root

  wp db query "SELECT COUNT(*) AS old_order_items
               FROM ${tp}woocommerce_order_items oi
               JOIN ${tp}posts p ON oi.order_id = p.ID
               WHERE p.post_type='shop_order'
                 AND p.post_date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" \
    --path="$path" --allow-root

  wp db query "SELECT COUNT(*) AS old_comments
               FROM ${tp}comments c
               JOIN ${tp}posts p ON p.ID = c.comment_post_ID
               WHERE p.post_type='shop_order'
                 AND p.post_date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" \
    --path="$path" --allow-root

  echo
  echo "WooCommerce 3-year cleanup completed."
}

########################
# DB size helpers
########################

print_db_sizes() {
  local path="$1"
  echo
  log "Current DB table sizes:"
  wp db size --all-tables --path="$path" --allow-root
}

########################
# Main
########################

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

check_php_and_extensions
check_wp_cli
choose_site

WP_PATH="$SELECTED_PATH"

detect_table_prefix "$WP_PATH"

print_db_sizes "$WP_PATH"

# D: wp_options cleanup (always, no prompt – your choice: Option 1)
cleanup_wp_options "$WP_PATH" "$DB_PREFIX"

# WooCommerce 3-year cleanup
woocommerce_cleanup_3y "$WP_PATH" "$DB_PREFIX"

echo
log "Final DB sizes after cleanup:"
wp db size --all-tables --path="$WP_PATH" --allow-root

echo
echo "Done."
