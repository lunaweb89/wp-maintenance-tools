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

    # Debugging: Echo input before processing
    read -rp "Select an option [1-10]: " CHOICE
    echo "DEBUG: You entered: '$CHOICE'"  # Debug line to check input value

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
