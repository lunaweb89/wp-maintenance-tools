#!/usr/bin/env bash
#
# mail-auto-ssl-multi.sh
#
# Multi-domain helper for mail SSL + DNS on a Postfix + Dovecot server.
#
# For each argument MAIL_FQDN:
#   - Ensure Cloudflare A record exists for MAIL_FQDN (if CF_API_TOKEN set)
#   - Ensure Let's Encrypt certificate exists (issue/renew via certbot if needed)
#
# For the FIRST MAIL_FQDN only:
#   - Apply cert to Postfix smtpd_tls_cert_file / smtpd_tls_key_file
#   - Apply cert to Dovecot ssl_cert / ssl_key
#   - Restart Postfix + Dovecot
#   - Verify TLS with openssl s_client on port 587
#
# Notes:
#   - Postfix and Dovecot generally use a SINGLE cert. The first domain you pass
#     will become the active SMTP TLS host. Point all WordPress SMTP configs to
#     that host for best compatibility.
#   - Script does NOT exit on individual failures. It logs and continues.
#
# Usage:
#   sudo bash mail-auto-ssl-multi.sh [--dry-run] mail.domain.com [mail.other.com ...]
#
# Cloudflare integration (optional):
#   export CF_API_TOKEN="your_cloudflare_api_token_here"
#

set -u
set -o pipefail

log()  { echo "[+] $*"; }
warn() { echo "[-] $*"; }
err()  { echo "[!] $*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------- DRY-RUN HANDLING ----------------------------- #

DRY_RUN=0

if [[ $# -gt 0 && "$1" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

dry_notice() {
  if (( DRY_RUN == 1 )); then
    echo "    (dry-run: no changes applied)"
  fi
}

if [[ "$(id -u)" -ne 0 ]]; then
  err "Run this script as root."
  exit 1
fi

if [[ $# -lt 1 ]]; then
  err "Usage: $0 [--dry-run] mail.domain.com [mail.other.com ...]"
  exit 1
fi

MAIL_FQDNS=("$@")

if (( DRY_RUN == 1 )); then
  log "DRY-RUN mode enabled: no configs, DNS, or services will be changed."
fi

# ----------------------------- GLOBAL SETUP ----------------------------- #

detect_server_ip() {
  local ip
  if have_cmd ip; then
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {print $7}')
  elif have_cmd hostname; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  else
    ip=""
  fi
  echo "$ip"
}

SERVER_IP="$(detect_server_ip)"
if [[ -z "$SERVER_IP" ]]; then
  warn "Could not detect server IP automatically."
else
  log "Detected server IP: $SERVER_IP"
fi

ensure_certbot() {
  if have_cmd certbot; then
    return
  fi
  if (( DRY_RUN == 1 )); then
    warn "certbot not found; would install it (apt/yum), but DRY-RUN is enabled."
    return
  fi
  log "certbot not found. Attempting to install..."
  if have_cmd apt; then
    apt update -y && apt install -y certbot || warn "Failed to install certbot via apt."
  elif have_cmd yum; then
    yum install -y certbot || warn "Failed to install certbot via yum."
  else
    warn "No known package manager (apt/yum). Please install certbot manually."
  fi
}

ensure_jq() {
  if have_cmd jq; then
    return
  fi
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    return
  fi
  if (( DRY_RUN == 1 )); then
    warn "jq not found; would install it, but DRY-RUN is enabled."
    return
  fi
  log "jq not found. Attempting to install (for Cloudflare API parsing)..."
  if have_cmd apt; then
    apt update -y && apt install -y jq || warn "Failed to install jq via apt."
  elif have_cmd yum; then
    yum install -y jq || warn "Failed to install jq via yum."
  else
    warn "No known package manager (apt/yum). Please install jq manually for Cloudflare support."
  fi
}

ensure_certbot
ensure_jq

CF_API_BASE="https://api.cloudflare.com/client/v4"

# ----------------------------- CLOUDFLARE HELPERS ----------------------------- #

root_from_mail_fqdn() {
  local fqdn="$1"
  echo "${fqdn#*.}"
}

cf_get_zone_id() {
  local root="$1"
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    warn "CF_API_TOKEN not set; skipping Cloudflare zone lookup for ${root}."
    return 1
  fi
  if ! have_cmd jq; then
    warn "jq not available; cannot parse Cloudflare API responses."
    return 1
  fi

  local resp success zone_id
  resp=$(curl -s -X GET \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CF_API_BASE}/zones?name=${root}&status=active")

  success=$(echo "$resp" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    warn "Cloudflare API error while getting zone for ${root}: $(echo "$resp" | jq -r '.errors[0].message // "unknown")'"
    return 1
  fi

  zone_id=$(echo "$resp" | jq -r '.result[0].id // empty')
  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    warn "No active zone found in Cloudflare for ${root}."
    return 1
  fi

  echo "$zone_id"
  return 0
}

cf_ensure_a_record() {
  local fqdn="$1"
  local ip="$2"
  if [[ -z "${CF_API_TOKEN:-}" || -z "$ip" ]]; then
    warn "Skipping Cloudflare DNS for ${fqdn} (CF_API_TOKEN or IP missing)."
    return
  fi
  if ! have_cmd jq; then
    warn "jq not available; skipping Cloudflare DNS for ${fqdn}."
    return
  fi

  local root zone_id resp rec_id current_ip

  root=$(root_from_mail_fqdn "$fqdn")
  zone_id=$(cf_get_zone_id "$root" || true)
  if [[ -z "$zone_id" ]]; then
    warn "Could not get Cloudflare zone ID for root domain ${root}; skipping DNS fix for ${fqdn}."
    return
  fi

  log "Cloudflare: Ensuring A record for ${fqdn} in zone ${root} (zone_id: ${zone_id})..."

  resp=$(curl -s -X GET \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CF_API_BASE}/zones/${zone_id}/dns_records?type=A&name=${fqdn}")

  rec_id=$(echo "$resp" | jq -r '.result[0].id // empty')
  current_ip=$(echo "$resp" | jq -r '.result[0].content // empty')

  if (( DRY_RUN == 1 )); then
    if [[ -n "$rec_id" && -n "$current_ip" ]]; then
      log "[DRY-RUN] Would update Cloudflare A record for ${fqdn}: ${current_ip} -> ${ip}"
    else
      log "[DRY-RUN] Would create Cloudflare A record for ${fqdn} -> ${ip}"
    fi
    dry_notice
    return
  fi

  if [[ -n "$rec_id" && -n "$current_ip" ]]; then
    if [[ "$current_ip" == "$ip" ]]; then
      log "Cloudflare A record for ${fqdn} already points to ${ip}."
      return
    fi
    log "Updating Cloudflare A record for ${fqdn}: ${current_ip} -> ${ip}"
    curl -s -X PUT \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "${CF_API_BASE}/zones/${zone_id}/dns_records/${rec_id}" \
      --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" >/dev/null 2>&1 || \
      warn "Failed to update A record for ${fqdn} via Cloudflare."
  else
    log "Creating Cloudflare A record for ${fqdn} -> ${ip}"
    curl -s -X POST \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "${CF_API_BASE}/zones/${zone_id}/dns_records" \
      --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" >/dev/null 2>&1 || \
      warn "Failed to create A record for ${fqdn} via Cloudflare."
  fi
}

# ----------------------------- CERTBOT / CERT HELPERS ----------------------------- #

cert_not_expiring_soon() {
  local cert_file="$1"
  if [[ ! -f "$cert_file" ]] || ! have_cmd openssl; then
    return 1
  fi
  local end_date now_ts end_ts days_left
  end_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
  if [[ -z "$end_date" ]]; then
    return 1
  fi
  now_ts=$(date +%s)
  end_ts=$(date -d "$end_date" +%s 2>/dev/null || echo "")
  if [[ -z "$end_ts" ]]; then
    return 1
  fi
  days_left=$(( (end_ts - now_ts) / 86400 ))
  (( days_left > 30 ))
  return $?
}

issue_or_renew_cert() {
  local fqdn="$1"
  local cert_dir="/etc/letsencrypt/live/${fqdn}"
  local cert_file="${cert_dir}/fullchain.pem"
  local key_file="${cert_dir}/privkey.pem"

  if [[ -f "$cert_file" && -f "$key_file" ]] && cert_not_expiring_soon "$cert_file"; then
    log "Existing valid certificate for ${fqdn} (not expiring within 30 days)."
    echo "$cert_file|$key_file"
    return
  fi

  if (( DRY_RUN == 1 )); then
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
      warn "[DRY-RUN] Certificate for ${fqdn} exists but may be expiring within 30 days."
      log "[DRY-RUN] Would run certbot certonly --standalone for ${fqdn}."
      dry_notice
      echo "$cert_file|$key_file"
    else
      warn "[DRY-RUN] No certificate for ${fqdn}. Would run certbot certonly --standalone for ${fqdn}."
      dry_notice
      echo "|"
    fi
    return
  fi

  log "No valid/long-lived certificate for ${fqdn}. Attempting issuance/renewal via certbot (standalone)..."
  log "NOTE: This may require port 80 to be free temporarily."

  local web_stopped=0
  for svc in lsws openlitespeed litespeed nginx apache2; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      if systemctl is-active --quiet "$svc"; then
        log "Stopping web service ${svc} temporarily for certbot standalone..."
        systemctl stop "$svc" || warn "Failed to stop ${svc}; certbot may fail if port 80 is in use."
        web_stopped=1
        break
      fi
    fi
  done

  certbot certonly --standalone \
    --non-interactive --agree-tos \
    -m "admin@${fqdn#*.}" \
    -d "${fqdn}" || warn "Certbot failed for ${fqdn}. Check DNS/port 80. Continuing..."

  if (( web_stopped == 1 )); then
    for svc in lsws openlitespeed litespeed nginx apache2; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        log "Starting web service ${svc} again..."
        systemctl start "$svc" || warn "Failed to restart ${svc}. Please check manually."
        break
      fi
    done
  fi

  if [[ -f "$cert_file" && -f "$key_file" ]]; then
    log "Certificate files ready for ${fqdn}:"
    log "  Cert: ${cert_file}"
    log "  Key : ${key_file}"
    echo "$cert_file|$key_file"
  else
    warn "Certificate files for ${fqdn} not found even after certbot. Skipping."
    echo "|"
  fi
}

# ----------------------------- POSTFIX / DOVECOT CONFIG ----------------------------- #

apply_mail_cert_to_postfix_dovecot() {
  local cert_file="$1"
  local key_file="$2"

  if [[ -z "$cert_file" || -z "$key_file" ]]; then
    warn "Cannot apply mail cert; cert or key path missing."
    return
  fi

  if (( DRY_RUN == 1 )); then
    log "[DRY-RUN] Would apply certificate to Postfix and Dovecot:"
    echo "         smtpd_tls_cert_file=${cert_file}"
    echo "         smtpd_tls_key_file=${key_file}"
    echo "         ssl_cert = <${cert_file}"
    echo "         ssl_key  = <${key_file}"
    dry_notice
    return
  fi

  log "Applying certificate to Postfix and Dovecot..."

  if have_cmd postconf; then
    log "Updating Postfix smtpd_tls_cert_file / smtpd_tls_key_file..."
    postconf -e "smtpd_tls_cert_file=${cert_file}" || warn "Failed to set Postfix smtpd_tls_cert_file."
    postconf -e "smtpd_tls_key_file=${key_file}"  || warn "Failed to set Postfix smtpd_tls_key_file."
  else
    warn "postconf not found; cannot update Postfix SSL paths."
  fi

  local dovecot_conf="/etc/dovecot/conf.d/10-ssl.conf"
  if [[ -f "$dovecot_conf" ]]; then
    local backup="${dovecot_conf}.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backing up Dovecot SSL config to ${backup}"
    cp -a "$dovecot_conf" "$backup"

    if grep -qE '^[[:space:]]*ssl_cert[[:space:]]*=' "$dovecot_conf"; then
      sed -i "s|^[[:space:]]*ssl_cert[[:space:]]*=.*|ssl_cert = <${cert_file}|" "$dovecot_conf"
    else
      echo "ssl_cert = <${cert_file}" >> "$dovecot_conf"
    fi

    if grep -qE '^[[:space:]]*ssl_key[[:space:]]*=' "$dovecot_conf"; then
      sed -i "s|^[[:space:]]*ssl_key[[:space:]]*=.*|ssl_key = <${key_file}|" "$dovecot_conf"
    else
      echo "ssl_key = <${key_file}" >> "$dovecot_conf"
    fi

    log "Updated Dovecot ssl_cert / ssl_key:"
    grep -E 'ssl_cert|ssl_key' "$dovecot_conf" || true
  else
    warn "Dovecot SSL config not found at ${dovecot_conf}; skipping Dovecot SSL update."
  fi

  log "Restarting Postfix and Dovecot..."
  systemctl restart postfix 2>/dev/null || warn "Failed to restart Postfix."
  systemctl restart dovecot 2>/dev/null || warn "Failed to restart Dovecot."

  systemctl is-active --quiet postfix && log "Postfix: active" || warn "Postfix is not active after restart!"
  systemctl is-active --quiet dovecot && log "Dovecot: active" || warn "Dovecot is not active after restart!"
}

verify_tls() {
  local fqdn="$1"
  if ! have_cmd openssl; then
    warn "openssl not found; skipping TLS verification."
    return
  fi

  log "Verifying TLS for ${fqdn}:587 (STARTTLS)..."
  local out
  out=$(echo | openssl s_client -starttls smtp -servername "$fqdn" -connect "${fqdn}:587" 2>/dev/null \
        | awk '/subject=|issuer=|Verify return code/ {print}')
  if [[ -z "$out" ]]; then
    warn "No output from openssl s_client; service may not be listening on 587 or TLS is misconfigured."
    return
  fi
  echo "$out"

  if echo "$out" | grep -q "Verify return code: 0 (ok)"; then
    log "TLS verification SUCCESS for ${fqdn}:587"
  else
    warn "TLS verification FAILED for ${fqdn}:587. WordPress may still see certificate errors."
  fi
}

# ----------------------------- MAIN LOOP ----------------------------- #

PRIMARY_DONE=0

for MAIL_FQDN in "${MAIL_FQDNS[@]}"; do
  echo
  echo "=========================================="
  echo " Processing mail host: ${MAIL_FQDN}"
  echo "=========================================="

  if [[ -n "$SERVER_IP" ]]; then
    cf_ensure_a_record "$MAIL_FQDN" "$SERVER_IP"
  else
    warn "Server IP not known; skipping Cloudflare DNS for ${MAIL_FQDN}."
  fi

  CERT_INFO="$(issue_or_renew_cert "$MAIL_FQDN")" || CERT_INFO="|"
  CERT_FILE="${CERT_INFO%%|*}"
  KEY_FILE="${CERT_INFO##*|}"

  if (( PRIMARY_DONE == 0 )); then
    log "Using ${MAIL_FQDN} as PRIMARY SMTP TLS host (will be applied to Postfix + Dovecot)."
    apply_mail_cert_to_postfix_dovecot "$CERT_FILE" "$KEY_FILE"
    verify_tls "$MAIL_FQDN"
    PRIMARY_DONE=1
  else
    log "${MAIL_FQDN} processed (DNS/cert). NOTE: Postfix/Dovecot still use the primary host's cert."
  fi
done

echo
echo "=========================================="
echo " Completed processing all mail hosts."
echo " Primary SMTP TLS host: ${MAIL_FQDNS[0]}"
echo " Configure WordPress SMTP as:"
echo "   Host: ${MAIL_FQDNS[0]}"
echo "   Port: 587"
echo "   Encryption: TLS"
if (( DRY_RUN == 1 )); then
  echo " (This was a DRY-RUN, no changes were applied.)"
fi
echo "=========================================="
