#!/bin/bash

# Ensure the script is run as root
if [[ "$EUID" -ne 0 ]]; then
    echo "[!] This script must be run as root."
    exit 1
fi

echo "[+] Running WooCommerce order pruning and database optimization..."

# Define the MySQL credentials (this should be customized if needed)
DB_USER="your_db_user"
DB_PASS="your_db_password"
DB_NAME="your_db_name"

# Step 1: WooCommerce order pruning (example query)
echo "[+] Pruning WooCommerce orders older than 30 days..."
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "DELETE FROM wp_posts WHERE post_type = 'shop_order' AND post_date < NOW() - INTERVAL 30 DAY;"

# Step 2: Optimize the database tables
echo "[+] Optimizing WordPress database tables..."
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "OPTIMIZE TABLE wp_posts, wp_postmeta, wp_comments, wp_commentmeta, wp_options, wp_terms, wp_termmeta, wp_term_taxonomy, wp_term_relationships, wp_users;"

# Optional: Indexing for improved performance (only if necessary)
echo "[+] Adding indexes (if necessary)..."
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "ALTER TABLE wp_posts ADD INDEX(post_date);"
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "ALTER TABLE wp_postmeta ADD INDEX(post_id);"

# Step 3: Additional cleanup (e.g., removing orphaned postmeta entries)
echo "[+] Removing orphaned postmeta entries..."
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "DELETE pm FROM wp_postmeta pm LEFT JOIN wp_posts wp ON pm.post_id = wp.ID WHERE wp.ID IS NULL;"

echo "[+] Cleanup and database optimization completed."
