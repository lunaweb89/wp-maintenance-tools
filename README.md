# wp-maintenance-tools

A modular WordPress server maintenance toolkit for Ubuntu + CyberPanel style hosting.

> **Goal:** Give you CLI tools to back up, restore, migrate, scan, and audit all WordPress installs under `/home` safely and repeatably.

All tools are designed to be run as **root** (e.g. `sudo -i`).

---

## 1. Quick Start

Run the main menu directly from GitHub:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-tools.sh)


===============================
  WordPress Maintenance Tools
===============================
  [1] DB cleanup (WooCommerce order pruning)
  [2] Malware scan (Maldet + ClamAV)
  [3] Backup ALL MySQL/MariaDB databases (local)
  [4] Backup ONLY WordPress sites to Dropbox (DB + files)
  [5] Exit
  [6] Restore WordPress from Dropbox (DB + files)
  [7] WordPress migration wizard (local backups)
  [8] Auto Backups to Dropbox (run now + install daily cron)
  [9] Fix WordPress file permissions
  [10] WordPress health audit

