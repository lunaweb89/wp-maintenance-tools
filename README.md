```markdown
# WordPress Maintenance Toolkit

A complete shell-based toolkit to manage, secure, back up, restore, and migrate multiple WordPress sites on any Linux server (CyberPanel-style `/home/<domain>/public_html` layout).

All tools run from **one universal launcher**, whether you log in as **root** or as a **sudo user**.

---

## 🚀 Universal Launcher (root OR sudo)

Copy/paste this single command on any server:

```bash
curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \
  | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )
```

What the launcher does:
- Detects whether you're running as root or sudo user  
- Auto-elevates safely  
- Downloads and runs the toolkit menu  
- Ensures all helper scripts run with correct privileges  

---

## 📦 Requirements

### System tools
- curl  
- bash  
- tar  
- gzip  
- find  
- rsync  

### Database tools
- mysql  
- mysqldump  

### Malware scanning
- maldet  
- clamav (clamscan)

### Dropbox backups (via rclone)

Configure a Dropbox remote named **dropbox**:

```bash
rclone config
```

Expected Dropbox structure:

```
Dropbox/
  wp-backups/
    maslike.es/
    piulike.com/
    pluslike.net/
```

Backups stored as:

```
wp-backups/<domain>/<domain>-db-YYYYMMDD-HHMMSS.sql.gz
wp-backups/<domain>/<domain>-files-YYYYMMDD-HHMMSS.tar.gz
```

---

## 🧰 Main Toolkit Menu

```
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
```

---

## 📝 Option Details (Full Explanations)

### 1️⃣ DB Cleanup (WooCommerce order pruning)
Runs `cleanup-script.sh` to:
- Remove old WooCommerce orders  
- Optimize tables  
- Add optional indexing  

---

### 2️⃣ Malware Scan (Maldet + ClamAV)
Runs `wp-malware-scan.sh`.

Features:
- Auto-detect all WP installs  
- Scan selected sites OR all sites  
- Uses Maldet + ClamAV  
- Logs stored in `/var/log/wp-malware-scan/`  

If malware is detected:
- Script prints infected file list  
- You can paste into ChatGPT for cleanup  

---

### 3️⃣ Backup WordPress Sites (Local Migration Backups)

Runs: `wp-migrate-local.sh --backup-only`

Creates:

```
/root/wp-migrate/<domain>/
  <domain>-db-YYYYMMDD-HHMMSS-migrate.sql.gz
  <domain>-files-YYYYMMDD-HHMMSS-migrate.tar.gz
```

After backup, script asks:

```
Do you want to push backups to a NEW server now via rsync?
```

If YES → You enter only new server IP.

Backups are pushed automatically to:

```
root@<IP>:/root/wp-migrate/
```

---

### 4️⃣ Backup WordPress Sites To Dropbox (DB + Files)

Runs: `wp-backup-dropbox.sh`

Features:
- Select 1 site, multiple sites, or all  
- Creates temporary DB + files backups  
- Uploads into:

```
dropbox:wp-backups/<domain>/
```

Temp files auto-removed.

Retention:
- Keep last 7 DB backups  
- Keep last 7 file backups  

---

### 5️⃣ Restore WordPress From Dropbox (DB + Files)

Runs: `wp-restore-dropbox.sh`

Flow:
1. Detect domains available in Dropbox  
2. Choose domain  
3. Fetch latest DB + file backup  
4. Parse DB credentials (from wp-config.php)  
5. Create DB + user  
6. Restore files to:

```
/home/<domain>/public_html/
```

7. Fix permissions  

Result → Fully restored WordPress site.

---

### 6️⃣ WordPress Migration Wizard (Server → Server)

Runs: `wp-migrate-local.sh`

**Mode 1 — Old Server**
- Detect sites  
- Select domains  
- Create migration backups  
- Optionally rsync to new server  

**Mode 2 — New Server**
- Detect backups from `/root/wp-migrate/<domain>/`  
- Restore DB + files  
- Fix permissions  

Complete migration workflow.

---

### 7️⃣ Auto Backups To Dropbox (Wizard + Cron)

Runs: `wp-backup-dropbox.sh --auto-setup`

Creates:
- Immediate full Dropbox backup of all WP sites  
- Installs daily cronjob (default 03:30)

Cron runs:

```
wp-backup-dropbox.sh --auto-run
```

Backups stored remotely only (no local storage).

---

### 8️⃣ Check & Fix WordPress File Permissions

Runs: `wp-fix-perms.sh`

Fixes:
- Directory permissions → 755  
- File permissions → 644  
- wp-config.php → 600  
- Ownership based on CyberPanel user  

---

### 9️⃣ WordPress Health Audit

Runs: `wp-health-audit.sh`

Checks:
- wp-admin / wp-includes / wp-content  
- Disk usage  
- Suspicious PHP functions (eval, base64_decode, etc.)  
- PHP version  
- World-writable files  
- Structural integrity  

---

## 🔁 Typical Usage Examples

### ✔ Full Migration Example (pluslike.net)

**Old server:**
1. Run toolkit → `[3] Backup WP sites`
2. Select site  
3. Choose *Yes* to rsync to new server  

**New server:**
1. Run toolkit → `[6] Migration wizard`
2. Mode 2  
3. Select site  

Migration complete.

---

### ✔ Daily Dropbox Auto Backup

Menu → `[7] Auto Backups Wizard`

- Runs backup immediately  
- Installs daily cron  
- No local retention  

---

## ⚠ Safety Notes

- Restore operations overwrite files + DB  
- Always test migration/restore on staging first  
- Ensure `rclone` Dropbox remote is configured before using options 4, 5, 7  

---

## ✔ Universal Launcher (Quick Copy)

```bash
curl -fsSL https://raw.githubusercontent.com/lunaweb89/wp-maintenance-tools/main/wp-toolkit.sh \
  | ( command -v sudo >/dev/null 2>&1 && sudo bash || bash )
```

---

## 🧑‍💻 Maintainer

This toolkit was engineered for safe, automated, repeatable WordPress management across multiple servers.
```
