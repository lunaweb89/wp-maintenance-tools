#!/bin/bash

# wp-migrate-local.sh
# This script handles the backup and migration of WordPress sites between servers.

# Prompt for New Server IP and Sudo User
read -p "Enter the NEW server IP address: " NEW_SERVER_IP
read -p "Enter the NEW server's sudo user: " NEW_SERVER_SUDO_USER

# Step 1: Backup WordPress Sites (Local Backup)
backup_wordpress_sites() {
    echo "[+] Running local migration-style backup for selected WordPress sites..."

    # Detect WordPress installations under /home
    WP_INSTALLS=()
    while IFS= read -r cfg; do
        WP_INSTALLS+=("$(dirname "$cfg")")
    done < <(find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null | sort)

    if ((${#WP_INSTALLS[@]} == 0)); then
        echo "[-] No WordPress installations found under /home."
        exit 1
    fi

    echo "[+] Detected WordPress installations:"
    local i=1 path parent domain
    for path in "${WP_INSTALLS[@]}"; do
        parent="$(dirname "$path")"
        domain="$(basename "$parent")"
        echo "  [$i] ${domain} (${path})"
        ((i++))
    done

    # Prompt user to select sites to backup
    echo "[+] Backup which sites? (e.g. 1 2 5, or A for all):"
    read -p "Selection: " SELECTED_SITES

    # Determine selected sites
    if [[ "$SELECTED_SITES" == "A" || "$SELECTED_SITES" == "a" ]]; then
        SELECTED_SITES=$(seq 1 ${#WP_INSTALLS[@]})
    fi

    for idx in $SELECTED_SITES; do
        if [[ $idx -gt 0 && $idx -le ${#WP_INSTALLS[@]} ]]; then
            path="${WP_INSTALLS[$idx-1]}"
            domain="$(basename "$path")"
            echo "[+] You selected to back up: ${domain}"
            
            # Define backup paths
            DB_NAME=$(grep "define('DB_NAME'" "${path}/wp-config.php" | awk -F"'" '{print $4}')
            DB_USER=$(grep "define('DB_USER'" "${path}/wp-config.php" | awk -F"'" '{print $4}')
            DB_PASS=$(grep "define('DB_PASSWORD'" "${path}/wp-config.php" | awk -F"'" '{print $4}')
            
            # Backup Database
            DB_BACKUP_PATH="/root/wp-migrate/${domain}/${domain}-db-$(date +%Y%m%d-%H%M%S)-migrate.sql.gz"
            echo "[+] Backing up ${domain} DB..."
            mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$DB_BACKUP_PATH"

            # Backup Files
            FILES_BACKUP_PATH="/root/wp-migrate/${domain}/${domain}-files-$(date +%Y%m%d-%H%M%S)-migrate.tar.gz"
            echo "[+] Backing up ${domain} files..."
            tar -czf "$FILES_BACKUP_PATH" -C "$path" .

            echo "[+] Backup for ${domain} completed."
        else
            echo "[-] Invalid selection: $idx"
        fi
    done
}

# Step 2: Push Backup to New Server via rsync
push_to_new_server() {
    echo "[+] Do you want to PUSH /root/wp-migrate to a remote NEW server now via rsync? (y/N):"
    read -p "Selection: " PUSH_TO_NEW_SERVER

    if [[ "$PUSH_TO_NEW_SERVER" == "y" || "$PUSH_TO_NEW_SERVER" == "Y" ]]; then
        # Perform rsync using the new server's sudo user
        echo "[+] Pushing /root/wp-migrate to $NEW_SERVER_SUDO_USER@$NEW_SERVER_IP:/root/wp-migrate/"

        # Ensure correct permissions for remote server
        sshpass -p "$NEW_SERVER_SUDO_USER_PASSWORD" rsync -avz /root/wp-migrate/ "$NEW_SERVER_SUDO_USER"@"$NEW_SERVER_IP":/root/wp-migrate/ --rsync-path="sudo rsync"

        if [[ $? -eq 0 ]]; then
            echo "[+] rsync push completed successfully."
        else
            echo "[-] rsync push failed. Please check SSH connectivity and rerun the push manually."
        fi
    else
        echo "[+] Backup process complete, no push to new server selected."
    fi
}

# Main function
main() {
    # Step 1: Backup selected sites
    backup_wordpress_sites

    # Step 2: Optionally push to new server
    push_to_new_server
}

# Execute main function
main
