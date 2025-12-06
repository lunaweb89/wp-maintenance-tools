WordPress Maintenance Toolkit

A complete shell-based toolkit to manage, secure, back up, restore, and migrate multiple WordPress sites on any Linux server (CyberPanel-style /home/<domain>/public_html layout).

All tools run from one universal launcher, whether you log in as root or as a sudo user.

🚀 Universal Launcher (root OR sudo)

Copy/paste this single command on any server:

curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \
  | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )

What the launcher does:

Detects whether you're running as root or sudo user

Auto-elevates safely

Downloads and runs the toolkit menu

Ensures all helper scripts run with correct privileges

📦 Requirements
System tools

curl

bash

tar

gzip

find

rsync

Database tools

mysql

mysqldump

Malware scanning

maldet

clamav (clamscan)

Dropbox backups (via rclone)

You must configure a Dropbox remote named dropbox:

rclone config

Expected Dropbox Folder Structure
Dropbox/
  wp-backups/
    maslike.es/
    piulike.com/
    pluslike.net/


Backups stored as:

wp-backups/<domain>/<domain>-db-YYYYMMDD-HHMMSS.sql.gz
wp-backups/<domain>/<domain>-files-YYYYMMDD-HHMMSS.tar.gz

🧰 Main Toolkit Menu
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

📝 Option Details With Full Explanations
1️⃣ DB Cleanup (WooCommerce order pruning)

Runs cleanup-script.sh

Removes old WooCommerce orders

Optimizes database tables

Optional indexing

2️⃣ Malware Scan (Maldet + ClamAV)

Runs wp-malware-scan.sh

Features:

Auto-detects WordPress installations

Scan selected sites OR all sites

Uses Maldet + ClamAV

Logs stored in /var/log/wp-malware-scan/

If malware is detected:

Script prints infected file list

You can paste it into ChatGPT for clean-up instructions

3️⃣ Backup WordPress Sites (Local Migration Backups)

Runs wp-migrate-local.sh --backup-only

Creates:

/root/wp-migrate/<domain>/
  <domain>-db-YYYYMMDD-HHMMSS-migrate.sql.gz
  <domain>-files-YYYYMMDD-HHMMSS-migrate.tar.gz


After backup, script asks:

Do you want to push backups to a NEW server now via rsync?


If YES → You only enter new server IP
Backups are sent to:

root@<IP>:/root/wp-migrate/

4️⃣ Backup WordPress Sites To Dropbox (DB + Files)

Runs wp-backup-dropbox.sh

Features:

Select 1 site, many sites, or all

Creates temporary DB + file archives

Uploads to:

dropbox:wp-backups/<domain>/


Temp files are deleted afterward.

Optional retention:

Keep last 7 DB backups

Keep last 7 file backups

5️⃣ Restore WordPress From Dropbox (DB + Files)

Runs wp-restore-dropbox.sh

Restore flow:

Lists domains found in Dropbox

You select domain

Script fetches latest DB + file backup

Reads DB credentials from wp-config.php

Creates database + user automatically

Restores files into:

/home/<domain>/public_html/


Fixes all permissions

Result: A fully restored, working WordPress site

6️⃣ WordPress Migration Wizard (Server → Server)

Runs wp-migrate-local.sh

Mode 1 — Old Server

Select domains

Create migration backups

Optional: push backups to new server

Mode 2 — New Server

Detect backups under /root/wp-migrate/<domain>/

Restore DB + files

Fix permissions

7️⃣ Auto Backups To Dropbox (Wizard + Cron)

Runs wp-backup-dropbox.sh --auto-setup

Creates:

Immediate backup of all WordPress sites

Installs a daily cronjob (default 03:30)

Cron runs silently:

wp-backup-dropbox.sh --auto-run


Backups are remote-only (no local files remain).

8️⃣ Check & Fix WordPress File Permissions

Runs wp-fix-perms.sh

Fixes:

directory permissions → 755

file permissions → 644

wp-config.php → 600

ownership based on CyberPanel user

9️⃣ WordPress Health Audit

Runs wp-health-audit.sh

Checks:

wp-admin / wp-includes / wp-content

Disk usage

Suspicious PHP functions

PHP version

World-writable files

File structure integrity

🔁 Typical Usage Examples
✔ Full Migration Example (pluslike.net)

Old server

[3] Backup WP sites

Select pluslike.net

Choose Yes to rsync to new server

New server

[6] Migration wizard

Mode 2

Select pluslike.net

➡️ Migration complete

✔ Daily Dropbox Auto Backup

Menu → [7] Auto Backups Wizard

Runs backup immediately

Installs daily cron

No local backup retention

⚠ Safety Notes

Restore operations overwrite files + DB

Test migrations/restores on staging first

Ensure rclone Dropbox remote is configured before using options 4, 5, 7

✔ Universal Launcher (Quick Copy)
curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \
  | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )

🧑‍💻 Maintainer

This toolkit was engineered for safe, automated, repeatable WordPress management across multiple servers.
