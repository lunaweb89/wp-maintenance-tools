#!/usr/bin/env bash
#
# wp-health-audit.sh
#
# Lightweight health audit for WordPress installs:
#   - Owner/group
#   - Disk usage
#   - Core directories/files presence
#   - World-writable files
#   - Simple suspicious pattern scan (eval/base64_decode in custom paths)
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

  for wp in "${WP_PATHS[@]}"; do
    local domain cfg owner group du

    domain="$(basename "$(dirname "$wp")")"
    cfg="${wp}/wp-config.php"
    owner="$(stat -c '%U' "$wp" 2>/dev/null || echo unknown)"
    group="$(stat -c '%G' "$wp" 2>/dev/null || echo unknown)"
    du="$(du -sh "$wp" 2>/dev/null | awk '{print $1}')"

    echo
    echo "============================================"
    echo " Site: ${domain}"
    echo " Path: ${wp}"
    echo "============================================"
    echo "Owner:Group  : ${owner}:${group}"
    echo "Disk usage   : ${du}"

    # Core directories
    for d in wp-admin wp-includes wp-content; do
      if [[ -d "${wp}/${d}" ]]; then
        echo "Core dir     : ${d} [OK]"
      else
        echo "Core dir     : ${d} [MISSING]"
      fi
    done

    # wp-config.php
    if [[ -f "${cfg}" ]]; then
      echo "wp-config.php: [OK]"
    else
      echo "wp-config.php: [MISSING]"
    fi

    # World-writable files
    local ww_count
    ww_count="$(find "$wp" -type f -perm -0002 2>/dev/null | wc -l | awk '{print $1}')"
    echo "World-writable files: ${ww_count}"

    if (( ww_count > 0 )); then
      echo "  (Consider fixing these with the 'Fix permissions' tool.)"
    fi

    # Very basic suspicious scan (exclude wp-admin/wp-includes)
    echo
    echo "Suspicious pattern scan (eval/base64_decode) in custom code:"
    find "$wp" -type f -name '*.php' \
      ! -path "${wp}/wp-admin/*" \
      ! -path "${wp}/wp-includes/*" \
      -print0 2>/dev/null \
      | xargs -0 grep -En 'eval\(|base64_decode\(' 2>/dev/null \
      | head -n 20 || echo "  No obvious suspicious patterns found in first 20 matches."

    echo
  done
}

main "$@"
