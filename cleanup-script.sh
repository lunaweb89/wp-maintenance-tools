#!/usr/bin/env bash
#
# WordPress / WooCommerce DB cleanup tool
# - Detects WP installs under /home/*/public_html
# - Lets you pick a site
# - Cleans WooCommerce data older than N years (you choose)
# - Creates a MySQL backup before deletion and deletes backup if success
# - Uses WP-CLI for safety
#

############################
# 0. Safety / Environment  #
############################

# Don't use "set -e" because we want to track errors manually and not bail on first SQL failure.

if ! command -v php >/dev/null 2>&1; then
  echo "ERROR: PHP CLI is not installed. Please install PHP and re-run."
  exit 1
fi

echo "OK: PHP found: $(php -v 2>/dev/null | head -n1)"

# Check mysqli extension
if ! php -m | grep -qi mysqli; then
  echo "PHP mysqli extension is missing. Attempting to install automatically..."

  if command -v apt-get >/dev/null 2>&1; then
    echo "Detected Debian/Ubuntu (apt). Installing php-mysql..."
    apt-get update -y
    apt-get install -y php-mysql || {
      echo "ERROR: Failed to install php-mysql via apt."
    }
  elif command -v dnf >/dev/null 2>&1; then
    echo "Detected dnf-based OS. Installing php-mysqlnd..."
    dnf install -y php-mysqlnd || {
      echo "ERROR: Failed to install php-mysqlnd via dnf."
    }
  elif command -v yum >/dev/null 2>&1; then
    echo "Detected yum-based OS. Installing php-mysqlnd..."
    yum install -y php-mysqlnd || {
      echo "ERROR: Failed to install php-mysqlnd via yum."
    }
  else
    echo "Could not auto-detect package manager. Please install mysqli (php-mysql / php-mysqlnd) manually."
  fi

  if ! php -m | grep -qi mysqli; then
    echo "ERROR: mysqli extension still not detected after attempted install."
    echo "Please install/enable it manually (package likely php-mysql or php-mysqlnd), then re-run this script."
    exit 1
  fi
fi

echo "OK: PHP mysqli extension is already enabled for CLI."

# Check WP-CLI
if ! command -v wp >/dev/null 2>&1; then
  echo "WP-CLI not found. Installing to /usr/local/bin/wp ..."
  curl -s -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || {
    echo "ERROR: Failed to download wp-cli.phar"
    exit 1
  }
  chmod +x wp-cli.phar
  mv wp-cli.phar /usr/local/bin/wp
fi

echo "OK: WP-CLI is available."


########################
# 1. Helper Functions  #
########################

has_woocommerce() {
  local path="$1"
  local tp="$2"

  # Check if plugin is installed
  if wp plugin is-installed woocommerce --path="$path" --allow-root >/dev/null 2>&1; then
    return 0
  fi

  # Fallback: check if core Woo tables exist
  if wp db query "SHOW TABLES LIKE '${tp}woocommerce_order_items';" \
     --path="$path" --allow-root --skip-column-names 2>/dev/null | \
     grep -q "${tp}woocommerce_order_items"; then
    return 0
  fi

  return 1
}

generic_cleanup() {
  local path="$1"
  local tp="$2"

  echo
  echo "=============================="
  echo " Generic safe cleanup (light) "
  echo "=============================="

  # 1) Clean WooCommerce sessions in wp_options
  echo "• Deleting WooCommerce session entries from ${tp}options ..."
  wp db query "DELETE FROM ${tp}options
               WHERE option_name LIKE '_wc_session_%'
                  OR option_name LIKE '_wc_session_expires_%';" \
      --path="$path" --allow-root 2>/dev/null || true

  # 2) Optionally: clean transients (safe but can cause cache rebuild)
  echo "• Deleting expired transients from ${tp}options ..."
  wp transient delete-expired --path="$path" --allow-root >/dev/null 2>&1 || true

  echo "Generic cleanup done."
}


woocommerce_cleanup_years() {
  local path="$1"
  local tp="$2"

  if ! has_woocommerce "$path" "$tp"; then
    echo
    echo "WooCommerce not detected on this site. Skipping WooCommerce cleanup."
    return
  fi

  echo
  read -rp "How many YEARS of WooCommerce order history would you like to KEEP? (Default: 3): " YEARS
  YEARS="${YEARS:-3}"

  if ! [[ "$YEARS" =~ ^[0-9]+$ ]]; then
    echo "Invalid input. Using default 3 years."
    YEARS=3
  fi

  echo
  echo "➡️  Will delete WooCommerce data OLDER than ${YEARS} years."
  echo "➡️  A full MySQL backup will be created BEFORE any deletion."
  echo

  # -------------------------
  # 1️⃣ Detect DB name
  # -------------------------
  DB_NAME=$(wp db query "SELECT DATABASE();" --path="$path" --allow-root --skip-column-names 2>/dev/null)

  if [[ -z "$DB_NAME" ]]; then
    echo "ERROR: Could not detect database name via WP-CLI."
    echo "Aborting cleanup."
    return 1
  fi

  # DOMAIN should be global, but if not set, derive from path
  if [[ -z "$DOMAIN" ]]; then
    local dir="${path%/public_html}"
    DOMAIN="${dir#/home/}"
  fi

  # -------------------------
  # 2️⃣ Create MySQL Backup
  # -------------------------
  local BACKUP_DIR="/root/wp-backups"
  mkdir -p "$BACKUP_DIR"

  local BACKUP_FILE="${BACKUP_DIR}/${DOMAIN}-$(date +%Y%m%d-%H%M%S).sql.gz"

  echo "🔄 Creating MySQL dump of DB '${DB_NAME}' -> $BACKUP_FILE"

  if ! mysqldump --single-transaction --quick --routines "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_FILE"; then
    echo "❌ Backup FAILED — aborting cleanup to avoid data loss."
    return 1
  fi

  echo "✅ Backup created successfully."
  echo

  # Track if any SQL step fails
  local CLEANUP_ERROR=0

  # -------------------------
  # 3️⃣ Helper table of old orders
  # -------------------------
  local helper="${tp}old_orders_${YEARS}y"

  echo "Ensuring helper table ${helper} exists..."
  wp db query "CREATE TABLE IF NOT EXISTS ${helper} (order_id BIGINT UNSIGNED PRIMARY KEY) ENGINE=InnoDB;" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Filling helper table with orders older than ${YEARS} years..."
  wp db query "INSERT IGNORE INTO ${helper} (order_id)
               SELECT ID FROM ${tp}posts
               WHERE post_type = 'shop_order'
                 AND post_date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo
  echo "🔎 Counts BEFORE deletion (older than ${YEARS} years):"

  echo "- Orders:"
  wp db query "SELECT COUNT(*) AS old_orders
               FROM ${tp}posts
               WHERE ID IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root

  echo "- Order items:"
  wp db query "SELECT COUNT(*) AS old_order_items
               FROM ${tp}woocommerce_order_items oi
               WHERE oi.order_id IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root

  echo "- Order itemmeta:"
  wp db query "SELECT COUNT(*) AS old_order_itemmeta
               FROM ${tp}woocommerce_order_itemmeta oim
               JOIN ${tp}woocommerce_order_items oi
                 ON oi.order_item_id = oim.order_item_id
               WHERE oi.order_id IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root

  echo "- Order comments (notes):"
  wp db query "SELECT COUNT(*) AS old_comments
               FROM ${tp}comments c
               JOIN ${tp}posts p ON p.ID = c.comment_post_ID
               WHERE p.ID IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root

  echo "- AutomateWoo logs older than ${YEARS} years:"
  wp db query "SELECT COUNT(*) AS aw_logs_old
               FROM ${tp}automatewoo_logs
               WHERE date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);" \
      --path="$path" --allow-root

  echo
  read -rp "Proceed with deletion of WooCommerce data older than ${YEARS} years? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled by user. Backup kept at: $BACKUP_FILE"
    return
  fi

  echo
  echo "=============================="
  echo "  Running WooCommerce cleanup "
  echo "=============================="

  # -------------------------
  # 4️⃣ Perform Deletes
  # -------------------------

  echo "Deleting old AutomateWoo log meta..."
  wp db query "DELETE FROM ${tp}automatewoo_log_meta
               WHERE log_id IN (
                 SELECT id FROM ${tp}automatewoo_logs
                 WHERE date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR)
               );" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Deleting old AutomateWoo logs..."
  wp db query "DELETE FROM ${tp}automatewoo_logs
               WHERE date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Deleting WooCommerce comments (order notes) for old orders..."
  wp db query "DELETE c FROM ${tp}comments c
               JOIN ${tp}posts p ON p.ID = c.comment_post_ID
               WHERE p.ID IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Deleting old WooCommerce order itemmeta..."
  wp db query "DELETE oim FROM ${tp}woocommerce_order_itemmeta oim
               JOIN ${tp}woocommerce_order_items oi
                 ON oi.order_item_id = oim.order_item_id
               WHERE oi.order_id IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Deleting old WooCommerce order items..."
  wp db query "DELETE FROM ${tp}woocommerce_order_items
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Deleting old WooCommerce orders (postmeta)..."
  wp db query "DELETE FROM ${tp}postmeta
               WHERE post_id IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Deleting old WooCommerce orders (posts)..."
  wp db query "DELETE FROM ${tp}posts
               WHERE ID IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Cleaning WooCommerce analytics tables..."
  wp db query "DELETE FROM ${tp}wc_order_product_lookup
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  wp db query "DELETE FROM ${tp}wc_order_stats
               WHERE order_id IN (SELECT order_id FROM ${helper});" \
      --path="$path" --allow-root || CLEANUP_ERROR=1

  echo "Dropping helper table ${helper}..."
  wp db query "DROP TABLE IF EXISTS ${helper};" \
      --path="$path" --allow-root || CLEANUP_ERROR=1


  # -------------------------
  # 5️⃣ Optimize large tables
  # -------------------------
  echo
  echo "Optimizing largest WooCommerce-related tables..."
  wp db query "OPTIMIZE TABLE
      ${tp}postmeta,
      ${tp}posts,
      ${tp}comments,
      ${tp}woocommerce_order_itemmeta,
      ${tp}woocommerce_order_items,
      ${tp}wc_order_stats,
      ${tp}wc_order_product_lookup;" \
      --path="$path" --allow-root || CLEANUP_ERROR=1


  # -------------------------
  # 6️⃣ Handle backup (delete or keep)
  # -------------------------
  if [[ "$CLEANUP_ERROR" -eq 0 ]]; then
    echo
    echo "✅ Cleanup finished with NO SQL errors."
    echo "🗑 Removing backup file: $BACKUP_FILE"
    rm -f "$BACKUP_FILE"
  else
    echo
    echo "❌ Cleanup encountered one or more SQL errors."
    echo "🔒 Backup has been preserved at: $BACKUP_FILE"
  fi

  echo
  echo "🎉 WooCommerce cleanup (older than ${YEARS} years) finished."
}


##############################
# 2. Detect WP installations #
##############################

echo
echo "Scanning for WordPress installations under /home/*/public_html..."

declare -a WP_PATHS
declare -a WP_DOMAINS

for wpdir in /home/*/public_html; do
  [ -d "$wpdir" ] || continue
  if [ -f "$wpdir/wp-config.php" ]; then
    parent="${wpdir%/public_html}"
    domain="${parent#/home/}"
    WP_PATHS+=("$wpdir")
    WP_DOMAINS+=("$domain")
  fi
done

if [ "${#WP_PATHS[@]}" -eq 0 ]; then
  echo "No WordPress installations found under /home/*/public_html."
  exit 1
fi

echo
echo "Found the following WordPress installs:"
for i in "${!WP_PATHS[@]}"; do
  idx=$((i+1))
  echo "  [${idx}] ${WP_DOMAINS[$i]}  (${WP_PATHS[$i]})"
done

echo
read -rp "Select site number to clean: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#WP_PATHS[@]}" ]; then
  echo "Invalid choice."
  exit 1
fi

SEL_INDEX=$((CHOICE-1))
WP_PATH="${WP_PATHS[$SEL_INDEX]}"
DOMAIN="${WP_DOMAINS[$SEL_INDEX]}"

echo
echo "Selected site:"
echo "  Domain: $DOMAIN"
echo "  Path  : $WP_PATH"

##############################
# 3. Detect table prefix     #
##############################

echo "Detecting DB table prefix via WP-CLI..."
TABLE_PREFIX=$(wp config get table_prefix --path="$WP_PATH" --allow-root --skip-column-names 2>/dev/null)

if [[ -z "$TABLE_PREFIX" ]]; then
  echo "WARNING: Could not detect table_prefix via WP-CLI, defaulting to 'wp_'."
  TABLE_PREFIX="wp_"
fi

echo "Detected table prefix: $TABLE_PREFIX"

#########################################
# 4. Show DB size BEFORE, run cleanup   #
#########################################

echo "Checking current DB size..."
wp db size --all-tables --path="$WP_PATH" --allow-root

# Light generic cleanup
generic_cleanup "$WP_PATH" "$TABLE_PREFIX"

# WooCommerce history cleanup with backup
woocommerce_cleanup_years "$WP_PATH" "$TABLE_PREFIX"

echo
echo "Final DB size after cleanup:"
wp db size --all-tables --path="$WP_PATH" --allow-root

echo
echo "Done."
