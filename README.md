README.md (Full Copy-Paste Version)
# WordPress Maintenance Toolkit

A complete shell-based toolkit to manage, secure, back up, restore, and migrate multiple WordPress sites on any Linux server (CyberPanel-style `/home/<domain>/public_html` layout).

All tools run from **one universal launcher**, whether you log in as **root** or a **sudo user**.

---

## 🚀 Universal Launcher (root OR sudo)

Copy/paste this single command on any server:

```bash
curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \
  | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )


The launcher will:

Detect whether you are root or sudo user

Elevate automatically

Load the toolkit menu

Execute all helper scripts as root safely

📦 Requirements
System tools

curl, bash, tar, gzip, find, rsync

MySQL tools: mysql, mysqldump

Malware scanning

maldet

clamav (clamscan)

Dropbox support

rclone

Must have a configured remote called dropbox

Run setup once:

rclone config

Directory structure on Dropbox:
Dropbox/
  wp-backups/
    maslike.es/
    piulike.com/
    pluslike.net/


Backups will be stored like:

wp-backups/<domain>/<domain>-db-YYYYMMDD-HHMMSS-<tag>.sql.gz
wp-backups/<domain>/<domain>-files-YYYYMMDD-HHMMSS-<tag>.tar.gz

🧰 Main Toolkit Menu

After launching, you will see:

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

📝 Option Details
1️⃣ DB Cleanup (WooCommerce order pruning)

Runs cleanup-script.sh

Removes old WooCommerce orders

Optimizes tables

Optional indexing depending on your settings

2️⃣ Malware Scan (Maldet + ClamAV)

Runs wp-malware-scan.sh
Features:

Detects all WP installs under /home

Select sites to scan OR scan all

Runs Maldet + ClamAV

Logs saved in /var/log/wp-malware-scan/

Summary clearly shows: CLEAN or INFECTED

If infected files are found:

The script prints a detected files section

You can paste that into ChatGPT for cleanup

3️⃣ Backup WordPress Sites (Local Migration Backups)

Runs: wp-migrate-local.sh --backup-only

Flow:

Detect WP sites.

You select:

Specific sites (e.g. 1 3)

Or A for all sites

Creates local backup set:

/root/wp-migrate/<domain>/
  <domain>-db-YYYYMMDD-HHMMSS-migrate.sql.gz
  <domain>-files-YYYYMMDD-HHMMSS-migrate.tar.gz


Optional:

Script asks if you want to PUSH backups to new server via rsync

Only enter new server IP

rsync target: /root/wp-migrate/

This is your OLD SERVER → NEW SERVER migration backup set.

4️⃣ Backup Only WordPress Sites to Dropbox

Runs: wp-backup-dropbox.sh

Features:

Select multiple WP sites OR all

Creates temporary DB + file archives

Uploads to:

dropbox:wp-backups/<domain>/


No local backup is kept

Optional rotation:

Keep last 7 DB backups

Keep last 7 file backups

5️⃣ Restore WordPress From Dropbox (DB + Files)

Runs: wp-restore-dropbox.sh

Process:

Script lists domains available in Dropbox.

You choose a domain.

Script restores:

Latest DB + file backup

Detects DB credentials from wp-config.php

Recreates DB + user automatically

Restores files to:

/home/<domain>/public_html/


Fixes ownership & permissions.

Result: fully restored site.

6️⃣ WordPress Migration Wizard (Server → Server)

Runs: wp-migrate-local.sh

Two modes:

Mode 1 — OLD SERVER

Detect sites

You select domains

Creates migration backups

Optionally rsyncs to new server

Mode 2 — NEW SERVER

Reads backups from /root/wp-migrate/<domain>/

Restores:

DB

Files

Permissions

This is the complete migration workflow.

7️⃣ Auto Backups To Dropbox (Wizard + Cron Installer)

Runs: wp-backup-dropbox.sh --auto-setup

Flow:

Creates IMMEDIATE backup of all WP sites to Dropbox

Installs a daily cronjob (default 03:30)

Cronjob runs silent mode:
wp-backup-dropbox.sh --auto-run

All backups are remote-only.
No local backup files remain.

8️⃣ Check & Fix WordPress File Permissions

Runs: wp-fix-perms.sh

Fixes:

File permissions

Directory permissions

wp-config.php → 600

Ownership based on CyberPanel account

9️⃣ WordPress Health Audit

Runs: wp-health-audit.sh

Checks:

Domain, disk usage

wp-admin, wp-includes, wp-content presence

world-writable files

suspicious patterns (eval(, base64_decode(, etc.)

PHP version checks

file structure integrity

Great for quick diagnosis.

🔁 Typical Usage
✔ Migration Example (pluslike.net)
Old server:

Menu → [3] Backup WP sites → select pluslike.net → Push to new server

New server:

Menu → [6] Migration wizard → Mode 2 → Restore pluslike.net

Done. Site live.

✔ Daily Dropbox Auto Backup

Menu → [7] Run Auto Backups Wizard

Immediately performs a backup

Installs daily cron

No local files stored

⚠️ Safety Notes

Restores overwrite files and databases

Always test on a staging server first

Ensure Dropbox remote (rclone) is configured before using Options 4, 5, 7

✔ Ready to Use

Paste the universal launcher anywhere and the toolkit works:

curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \
  | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )

🧑‍💻 Maintainer

This toolkit was engineered for automated, safe, repeatable WordPress management across multiple servers
