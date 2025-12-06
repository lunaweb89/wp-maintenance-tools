# WordPress Maintenance Toolkit

A collection of shell tools to manage, migrate, and protect multiple WordPress sites on a single server (typically `/home/<domain>/public_html` layout such as CyberPanel).

All scripts are designed to be run **as root** (direct root login or via `sudo`), using one **universal launcher**.

---

## 🚀 Universal Launcher (root or sudo user)

Run this on **any server** (old or new), as root *or* as a sudo-capable user:

```bash
curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \
  | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )

===============================
  WordPress Maintenance Tools
===============================
  [1] DB cleanup (WooCommerce order pruning)
  [2] Run Malware scan (Maldet + ClamAV)
  [3] Backup WordPress sites (local migration backups)
  [4] Backup ONLY WordPress sites to Dropbox (DB + files)
  [5] Restore WordPress from Dropbox (DB + files)
  [6] Run WordPress migration wizard (local backups, server to server)
  [7] Run Auto Backups Wizard to Dropbox (run now + install daily cron)
  [8] Check & Fix WordPress file permissions
  [9] Run WordPress health audit
  [10] Exit

