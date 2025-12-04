#!/usr/bin/env bash
#
# WordPress maintenance / cleanup tool
# - auto-detects WP installs under /home/*/public_html
# - runs DB cleanup using WP-CLI
# - keeps last 3 years of WooCommerce / AutomateWoo data
# - now includes preflight check to ensure PHP mysqli extension is installed

set -euo pipefail

#######################################
# Utility: colored echo
#######################################
cecho() {
  local color=$1; shift
  local code=""
  case "$color" in
    red)    code="31";;
    green)  code="32";;
    yellow) code="33";;
    blue)   code="34";;
    magenta)code="35";;
    cyan)   code="36";;
    *)      code="0";;
  esac
  printf "\e[%sm%s\e[0m\n" "$code" "$*"
}

#######################################
# Preflight: ensure PHP + mysqli
#######################################
ensure_php_mysqli() {
  if ! command -v php >/dev/null 2>&1; then
    cecho red "ERROR: php CLI is not installed. Please install PHP first."
    exit 1
  fi

  if php -m | grep -qi mysqli; then
    cecho green "OK: PHP mysqli extension is already enabled for CLI."
    return 0
  fi

  cecho yellow "PHP mysqli extension is missing. Attempting to install automatically..."

  if command -v apt-get >/dev/null 2>&1; then
    cecho cyan "Detected Debian/Ubuntu (apt). Installing php-mysql..."
    apt-get update -y
    apt-get install -y php-mysql || true
  elif command -v dnf >/dev/null 2>&1; then
    cecho cyan "Detected RHEL/CentOS/Alma/Rocky (dnf). Installing php-mysqlnd..."
    dnf install -y php-mysqlnd || true
  elif command -v yum >/dev/null 2>&1; then
    cecho cyan "Detected RHEL/CentOS (yum). Installing php-mysqlnd..."
    yum install -y php-mysqlnd || true
  else
    cecho red "ERROR: Could not detect a supported package manager (apt, dnf, yum)."
    cecho red "Please install the mysqli extension manually for the PHP CLI."
  fi

  # Re-check
  if php -m | grep -qi mysqli; then
    cecho green "Success: mysqli extension is now available for PHP CLI."
  else
    cecho red "ERROR: mysqli extension still not detected after attempted install."
    cecho red "Please install/enable it manually (package likely php-mysql or php-mysqlnd),"
    cecho red "then re-run this script."
    exit 1
  fi
}

#######################################
# Preflight: ensure WP-CLI
#######################################
ensure_wp_cli() {
  if command -v wp >/dev/null 2>&1; then
    cecho green "OK: WP-CLI is available."
    return 0
  fi

  cecho yellow "WP-CLI not found. Installing wp-cli.phar to /usr/local/bin/wp ..."
  curl -s -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  mv wp-cli.phar /usr/local/bin/wp

  if command -v wp >/dev/null 2>&1; then
    cecho green "WP-CLI installed successfully."
  else
    cecho red "ERROR: Failed to install WP-CLI. Please install it manually and re-run."
    exit 1
  fi
}

#######################################
# Detect WordPress installs
#######################################
find_wp_installs() {
  mapfile -t WP_PATHS < <(find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null | sort)
  if [ "${#WP_PATHS[@]}" -eq 0 ]; then
    cecho red "No wp-config.php files found under /home. Nothing to do."
    exit 1
  fi
}

#######################################
# Let user choose site
#######################################
select_wp_site() {
  cecho cyan "Scanning for WordPress installations under /home/*/public_html..."
  find_wp_installs

  cecho green ""
  cecho green "Found the following WordPress installs:"
  local i=1
  for path in "${WP_PATHS[@]}"; do
    local root dir domain
    root="$(dirname "$path")"
    dir="$(dirname "$root")"
    domain="$(basename "$dir")"
    printf "  [%d] %s  (%s)\n" "$i" "$domain" "$root"
    i=$((i+1))
  done

  echo ""
  read -rp "Select site number to clean: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#WP_PATHS[@]}" ]; then
    cecho red "Invalid selection."
    exit 1
  fi

  SELECTED_ROOT="$(dirname "${WP_PATHS[$((choice-1))]}")"
  SELECTED_DOMAIN="$(basename "$(dirname "$SELECTED_ROOT")")"

  cecho green ""
  cecho green "Selected site:"
  cecho green "  Domain: $SELECTED_DOMAIN"
  cecho green "  Path  : $SELECTED_ROOT"
}

#######################################
# Main cleanup logic (same as before)
#######################################
cleanup_site() {
  local ROOT="$SELECTED_ROOT"

  cecho cyan "Detecting DB table prefix via WP-CLI..."
  local PREFIX
  PREFIX=$(cd "$ROOT" && wp db prefix --allow-root 2>/dev/null | tr -d '[:space:]')
  if [ -z "$PREFIX" ]; then
    cecho red "Could not detect DB prefix. Aborting."
    exit 1
  fi
  cecho green "Detected table prefix: $PREFIX"

  cecho cyan "Checking current DB size..."
  cd "$ROOT"
  wp db size --all-tables --allow-root

  # create helper table for old orders
  cecho cyan "Ensuring helper table ${PREFIX}old_orders_3y exists..."
  wp db query "CREATE TABLE IF NOT EXISTS ${PREFIX}old_orders_3y (order_id BIGINT(20) UNSIGNED PRIMARY KEY) ENGINE=InnoDB;" --allow-root

  cecho cyan "Filling helper table with orders older than 3 years..."
  wp db query "INSERT IGNORE INTO ${PREFIX}old_orders_3y (order_id) SELECT ID FROM ${PREFIX}posts WHERE post_type = 'shop_order' AND post_date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" --allow-root

  cecho green "Counts BEFORE deletion (older than 3 years):"
  wp db query "SELECT COUNT(*) AS old_orders FROM ${PREFIX}old_orders_3y;" --allow-root
  wp db query "SELECT COUNT(*) AS old_order_items FROM ${PREFIX}woocommerce_order_items oi JOIN ${PREFIX}old_orders_3y o ON oi.order_id = o.order_id;" --allow-root
  wp db query "SELECT COUNT(*) AS old_order_itemmeta FROM ${PREFIX}woocommerce_order_itemmeta oim JOIN ${PREFIX}woocommerce_order_items oi ON oi.order_item_id = oim.order_item_id JOIN ${PREFIX}old_orders_3y o ON oi.order_id = o.order_id;" --allow-root
  wp db query "SELECT COUNT(*) AS old_comments FROM ${PREFIX}comments c JOIN ${PREFIX}old_orders_3y o ON c.comment_post_ID = o.order_id;" --allow-root
  wp db query "SELECT COUNT(*) AS aw_logs_old FROM ${PREFIX}automatewoo_logs WHERE date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" --allow-root

  read -rp $'\e[33mProceed with deletion of data older than 3 years? (y/N): \e[0m' CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    cecho yellow "Aborting cleanup by user choice."
    exit 0
  fi

  cecho cyan "Deleting old AutomateWoo log meta..."
  wp db query "DELETE lm FROM ${PREFIX}automatewoo_log_meta lm JOIN ${PREFIX}automatewoo_logs l ON lm.log_id = l.id WHERE l.date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" --allow-root

  cecho cyan "Deleting old AutomateWoo logs..."
  wp db query "DELETE FROM ${PREFIX}automatewoo_logs WHERE date < DATE_SUB(CURDATE(), INTERVAL 3 YEAR);" --allow-root

  cecho cyan "Deleting old WooCommerce comments (order notes)..."
  wp db query "DELETE c FROM ${PREFIX}comments c JOIN ${PREFIX}old_orders_3y o ON c.comment_post_ID = o.order_id;" --allow-root
  wp db query "DELETE FROM ${PREFIX}commentmeta WHERE comment_id NOT IN (SELECT comment_ID FROM ${PREFIX}comments);" --allow-root

  cecho cyan "Deleting old WooCommerce order itemmeta..."
  wp db query "DELETE oim FROM ${PREFIX}woocommerce_order_itemmeta oim JOIN ${PREFIX}woocommerce_order_items oi ON oi.order_item_id = oim.order_item_id JOIN ${PREFIX}old_orders_3y o ON oi.order_id = o.order_id;" --allow-root

  cecho cyan "Deleting old WooCommerce order items..."
  wp db query "DELETE oi FROM ${PREFIX}woocommerce_order_items oi JOIN ${PREFIX}old_orders_3y o ON oi.order_id = o.order_id;" --allow-root

  cecho cyan "Deleting old orders from posts + postmeta..."
  wp db query "DELETE pm FROM ${PREFIX}postmeta pm JOIN ${PREFIX}old_orders_3y o ON pm.post_id = o.order_id;" --allow-root
  wp db query "DELETE FROM ${PREFIX}posts WHERE ID IN (SELECT order_id FROM ${PREFIX}old_orders_3y);" --allow-root

  cecho cyan "Cleaning WooCommerce analytics / lookup tables..."
  wp db query "DELETE FROM ${PREFIX}wc_order_stats WHERE order_id IN (SELECT order_id FROM ${PREFIX}old_orders_3y);" --allow-root
  wp db query "DELETE FROM ${PREFIX}wc_order_product_lookup WHERE order_id IN (SELECT order_id FROM ${PREFIX}old_orders_3y);" --allow-root
  wp db query "DELETE FROM ${PREFIX}wc_order_coupon_lookup WHERE order_id IN (SELECT order_id FROM ${PREFIX}old_orders_3y);" --allow-root
  wp db query "DELETE FROM ${PREFIX}wc_order_tax_lookup WHERE order_id IN (SELECT order_id FROM ${PREFIX}old_orders_3y);" --allow-root
  wp db query "DELETE FROM ${PREFIX}wc_order_addresses WHERE order_id IN (SELECT order_id FROM ${PREFIX}old_orders_3y);" --allow-root

  cecho cyan "Dropping helper table ${PREFIX}old_orders_3y..."
  wp db query "DROP TABLE IF EXISTS ${PREFIX}old_orders_3y;" --allow-root

  cecho cyan "Optimizing largest tables..."
  wp db query "OPTIMIZE TABLE ${PREFIX}postmeta, ${PREFIX}posts, ${PREFIX}comments, ${PREFIX}woocommerce_order_items, ${PREFIX}woocommerce_order_itemmeta, ${PREFIX}wc_order_stats, ${PREFIX}wc_order_product_lookup;" --allow-root

  cecho green "Final DB size after cleanup:"
  wp db size --all-tables --allow-root
}

#######################################
# Main
#######################################
ensure_php_mysqli
ensure_wp_cli
select_wp_site
cleanup_site

cecho green "Done."
