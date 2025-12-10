cat >/root/vps-health-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "======== VPS HEALTH CHECK: $(date) ========"
echo
echo "[Load / Uptime]"
uptime
echo

echo "[Top 5 CPU processes]"
ps aux --sort=-%cpu | head -n 6
echo

echo "[Top 5 RAM processes]"
ps aux --sort=-%mem | head -n 6
echo

echo "[Memory]"
free -m
echo

echo "[Disk usage]"
df -h
echo

echo "[Failed services]"
systemctl --failed || true
echo

echo "[Last 10 critical log entries]"
journalctl -p 3 -xb | tail -n 10 || true
echo "==========================================="
EOF

chmod +x /root/vps-health-check.sh
