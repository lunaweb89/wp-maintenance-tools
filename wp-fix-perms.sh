#!/usr/bin/env bash
#
# wp-fix-perms.sh
#
# Detect WordPress installations under /home and fix:
#   - Ownership based on current owner of wp-config.php
#   - Directories → 755
#   - Files      → 644
#   - wp-config.php → 600
#

set -euo pipefail

log()  { echo "[+] $*"; }
warn() { echo "[-] $*"; }
err()  { echo "[!] $*" >&2; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root."
    echo "Use the toolkit launcher instead:"
    echo "  curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \\"
    echo "    | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )"
    exit 1
  fi
}

discover_wp_paths() {
  mapfile -t WP_PATHS < <(
    find /home -maxdepth 3 -type f -name "wp-config.php" 2>/dev/null \
      | sed 's#/wp-config.php$##' | sort
  )
}

main() {
  require_root
  discover_wp_paths

  if [[ ${#WP_PATHS[@]} -eq 0 ]]; then
    warn "No WordPress installations found under /home."
    exit 0
  fi

  echo
  log "Detected WordPress installations:"
  local i=1
  for wp in "${WP_PATHS[@]}"; do
    local domain
    domain="$(basename "$(dirname "$wp")")"
    echo "  [$i] ${domain} (${wp})"
    ((i++))
  done
  echo "  [A] All sites"
  echo

  local sel
  read -rp "Fix permissions for which site? (number or A for all): " sel

  declare -a TARGETS=()

  if [[ "$sel" =~ ^[Aa]$ ]]; then
    TARGETS=("${WP_PATHS[@]}")
  else
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#WP_PATHS[@]} )); then
      err "Invalid selection."
      exit 1
    fi
    TARGETS+=("${WP_PATHS[sel-1]}")
  fi

  for wp in "${TARGETS[@]}"; do
    local domain cfg owner group
    domain="$(basename "$(dirname "$wp")")"
    cfg="${wp}/wp-config.php"
    if [[ -f "$cfg" ]]; then
      owner="$(stat -c '%U' "$cfg" 2>/dev/null || echo root)"
      group="$(stat -c '%G' "$cfg" 2>/dev/null || echo root)"
    else
      owner="root"
      group="root"
    fi

    echo
    log "Fixing permissions for ${domain} (${wp}) ..."
    log "  Owner:Group -> ${owner}:${group}"

    chown -R "${owner}:${group}" "$wp" 2>/dev/null || true
    find "$wp" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$wp" -type f -exec chmod 644 {} \; 2>/dev/null || true
    [[ -f "$cfg" ]] && chmod 600 "$cfg" 2>/dev/null || true

    log "Permissions fixed for ${domain}."
  done
}

main "$@"
