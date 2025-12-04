#!/usr/bin/env bash
# woo_log_cleanup.sh
# Cleanup AutomateWoo logs older than N years for any WP site on this server.
# Auto-detects WordPress installs under /home/*/public_html.

set -euo pipefail

### Helper functions ###########################################################

die() {
  echo "ERROR: $*" >&2
  exit 1
}

prompt_confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N]: " ans
  case "$ans" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

### 1. Find WordPress installations ###########################################

echo "Scanning for WordPress installations under /home/*/public_html..."

WP_SITES=()
for d in /home/*/public_html; do
  if [ -f "$d/wp-config.php" ]; then
    WP_SITES+=("$d")
  fi
done

if [ "${#WP_SITES[@]}" -eq 0 ]; then
  die "No WordPress installs found under /home/*/public_html"
fi

echo
echo "Found the following WordPress installs:"
i=1
for path in "${WP_SITES[@]}"; do
  domain="$(basename "$(dirname "$path")")"
  echo "  [$i] $domain  ($path)"
  i=$((i+1))
done

if [ "${#WP_SITES[@]}" -eq 1 ]; then
  CHOICE=1
  echo
  echo "Only one site found – selecting [1]."
else
  echo
  read -r -p "Select site number to clean: " CHOICE
fi

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#WP_SITES[@]}" ]; then
  die "Invalid selection."
fi

WP_PATH="${WP_SITES[$((CHOICE-1))]}"
DOMAIN="$(basename "$(dirname "$WP_PATH")")"

echo
echo "Selected site:"
echo "  Domain: $DOMAIN"
echo "  Path  : $WP_PATH"

### 2. Detect WP owner and DB prefix ###########################################

if ! command -v wp >/dev/null 2>&1; then
  die "wp (WP-CLI) not found in PATH. Install WP-CLI first."
fi

OWNER="$(stat -c '%U' "$WP_PATH" 2>/dev/null || stat -f '%Su' "$WP_PATH" 2>/dev/null || true)"
[ -z "$OWNER" ] && die "Unable to determine filesystem owner for $WP_PATH"

WP="sudo -u $OWNER -i -- wp --path=$WP_PATH"

echo
echo "Detecting DB table prefix via WP-CLI..."
DB_PREFIX="$($WP db prefix --quiet)"
[ -z "$DB_PREFIX" ] && die "Could not detect DB prefix."

echo "DB prefix detected: $DB_PREFIX"

### 3. Ask how many years of history to keep ###################################

echo
read -r -p "Keep how many years of AutomateWoo log history? [3]: " YEARS
YEARS="${YEARS:-3}"

if ! [[ "$YEARS" =~ ^[0-9]+$ ]] || [ "$YEARS" -lt 1 ]; then
  die "Years must be a positive integer."
fi

echo
echo "Summary:"
echo "  Site          : $DOMAIN"
echo "  WP path       : $WP_PATH"
echo "  DB prefix     : $DB_PREFIX"
echo "  Keep history  : $YEARS years"

### 4. Show what will be cleaned ###############################################

echo
echo "Checking how many AutomateWoo logs are older than $YEARS year(s)..."

AW_LOGS_OLD="$($WP db query \
  "SELECT COUNT(*) AS cnt FROM ${DB_PREFIX}automatewoo_logs WHERE date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);" \
  --skip-column-names || echo 0)"

AW_LOGMETA_OLD="$($WP db query \
  "SELECT COUNT(*) AS cnt FROM ${DB_PREFIX}automatewoo_log_meta lm JOIN ${DB_PREFIX}automatewoo_logs l ON lm.log_id = l.id WHERE l.date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);" \
  --skip-column-names || echo 0)"

echo "  Old AutomateWoo logs      : $AW_LOGS_OLD"
echo "  Old AutomateWoo log_meta  : $AW_LOGMETA_OLD"

if [ "$AW_LOGS_OLD" -eq 0 ] && [ "$AW_LOGMETA_OLD" -eq 0 ]; then
  echo
  echo "Nothing older than $YEARS year(s) to clean. Exiting."
  exit 0
fi

echo
echo "This will PERMANENTLY DELETE AutomateWoo logs older than $YEARS year(s)"
echo "for site: $DOMAIN"
echo
echo "Type exactly: DELETE-AUTOMATEWOO-LOGS-$DOMAIN"
read -r -p "> " CONFIRM

if [ "$CONFIRM" != "DELETE-AUTOMATEWOO-LOGS-$DOMAIN" ]; then
  echo "Confirmation phrase mismatch. Aborting."
  exit 1
fi

### 5. Perform cleanup #########################################################

echo
echo "Deleting AutomateWoo log_meta older than $YEARS year(s)..."
$WP db query \
  "DELETE lm FROM ${DB_PREFIX}automatewoo_log_meta lm JOIN ${DB_PREFIX}automatewoo_logs l ON lm.log_id = l.id WHERE l.date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);" \
  >/dev/null 2>&1 || echo "Warning: log_meta delete encountered an issue (table may not exist?)."

echo "Deleting AutomateWoo logs older than $YEARS year(s)..."
$WP db query \
  "DELETE FROM ${DB_PREFIX}automatewoo_logs WHERE date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);" \
  >/dev/null 2>&1 || echo "Warning: logs delete encountered an issue (table may not exist?)."

### 6. Show remaining counts ###################################################

AW_LOGS_LEFT="$($WP db query \
  "SELECT COUNT(*) AS cnt FROM ${DB_PREFIX}automatewoo_logs;" \
  --skip-column-names || echo 0)"

AW_LOGS_OLD_LEFT="$($WP db query \
  "SELECT COUNT(*) AS cnt FROM ${DB_PREFIX}automatewoo_logs WHERE date < DATE_SUB(CURDATE(), INTERVAL ${YEARS} YEAR);" \
  --skip-column-names || echo 0)"

echo
echo "Cleanup complete."
echo "  Remaining AutomateWoo logs total    : $AW_LOGS_LEFT"
echo "  Remaining logs older than $YEARS y  : $AW_LOGS_OLD_LEFT"

echo
echo "Tip: you can now run:"
echo "  sudo -u $OWNER -i -- wp db optimize --path=$WP_PATH"
echo "to reclaim space at the DB level (optional)."
