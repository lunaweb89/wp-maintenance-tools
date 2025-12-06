#!/usr/bin/env bash
#
# wp-health-audit.sh
#
# Basic health audit for WordPress sites under /home.
#

set -euo pipefail

log()  { echo "[+] $*"; }
warn() { echo "[-] $*"; }

discover_wp_paths() {
  mapfile -t WP_PATHS < <(
    find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null \
      | sed 's#/wp-config.php$##' | sort
  )
}

main() {
  discover_wp_paths
  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found."
    exit 0
  fi

  log "Running basic health audit for WordPress sites..."

  for wp in "${WP_PATHS[@]}"; do
    local domain
    domain="$(basename "$(dirname "$wp")")"

    echo
    echo "==============================="
    echo " Health report for: $domain"
    echo " Path: $wp"
    echo "==============================="

    local owner group
    owner="$(stat -c '%U' "$wp" 2>/dev/null || echo 'unknown')"
    group="$(stat -c '%G' "$wp" 2>/dev/null || echo 'unknown')"
    echo "Owner/Group: ${owner}:${group}"

    local du
    du="$(du -sh "$wp" 2>/dev/null | awk '{print $1}')"
    echo "Disk usage: ${du:-unknown}"

    [[ -f "$wp/wp-admin/index.php" ]] && echo "Core: wp-admin present" || echo "Core: MISSING wp-admin/index.php"
    [[ -f "$wp/wp-includes/version.php" ]] && echo "Core: wp-includes/version.php present" || echo "Core: MISSING wp-includes/version.php"

    local uploads="${wp}/wp-content/uploads"
    if [[ -d "$uploads" ]]; then
      echo "Uploads dir: present at $uploads"
    else
      echo "Uploads dir: MISSING ($uploads)"
    fi

    local ww_count
    ww_count="$(find "$wp" -type f -perm -0002 2>/dev/null | wc -l)"
    echo "World-writable files: $ww_count"

    local sus_count
    sus_count="$(grep -Rsl --exclude-dir=wp-includes --exclude-dir=wp-admin -E "eval\\(" "$wp" 2>/dev/null | wc -l)"
    sus_count=$((sus_count + $(grep -Rsl --exclude-dir=wp-includes --exclude-dir=wp-admin -E "base64_decode\\(" "$wp" 2>/dev/null | wc -l)))
    echo "Suspicious PHP files (eval/base64_decode): $sus_count (manual review recommended if > 0)"
  done

  echo
  log "Health audit completed."
}

main "$@"
