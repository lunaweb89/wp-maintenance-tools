#!/usr/bin/env bash
#
# wp-fix-perms.sh
#
# Fix permissions for WordPress installs under /home:
#   - Directories: 755
#   - Files: 644
#   - wp-config.php: 600
#   - Ownership taken from wp-config.php file owner
#

set -euo pipefail

log()  { echo "[+] $*"; }
warn() { echo "[-] $*"; }
err()  { echo "[!] $*" >&2; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "Must be run as root."
    exit 1
  fi
}

discover_wp_paths() {
  mapfile -t WP_PATHS < <(
    find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null \
      | sed 's#/wp-config.php$##' | sort
  )
}

fix_one() {
  local wp="$1"
  local domain
  domain="$(basename "$(dirname "$wp")")"
  log "Fixing permissions for: $domain ($wp)"

  local owner group
  owner="$(stat -c '%U' "$wp/wp-config.php" 2>/dev/null || echo root)"
  group="$(stat -c '%G' "$wp/wp-config.php" 2>/dev/null || echo root)"
  log "Detected owner: ${owner}:${group}"

  chown -R "${owner}:${group}" "$wp" 2>/dev/null || true
  find "$wp" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$wp" -type f -exec chmod 644 {} \; 2>/dev/null || true
  [[ -f "$wp/wp-config.php" ]] && chmod 600 "$wp/wp-config.php" 2>/dev/null || true

  log "Permissions fixed for ${domain}."
}

main() {
  require_root
  discover_wp_paths
  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found."
    exit 0
  fi

  echo
  log "Detected WordPress installs:"
  local i=1
  for wp in "${WP_PATHS[@]}"; do
    local domain
    domain="$(basename "$(dirname "$wp")")"
    echo "  [$i] ${domain} (${wp})"
    ((i++))
  done
  echo "  [A] All sites"
  echo

  read -rp "Fix permissions for which site? (number or A for all): " sel

  if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#WP_PATHS[@]} )); then
    fix_one "${WP_PATHS[sel-1]}"
  elif [[ "$sel" == "A" || "$sel" == "a" ]]; then
    for wp in "${WP_PATHS[@]}"; do
      fix_one "$wp"
    done
    log "Permissions fixed for all WordPress sites."
  else
    warn "Invalid selection; no changes made."
  fi
}

main "$@"
