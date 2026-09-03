**An automated, read-only PowerShell operational health check and exception-based monitoring dashboard for Veritas NetBackup 8.x, 9.x, and 10.x enterprise environments.**

# NetBackup Enterprise Operational Health Dashboard

A unified, read-only PowerShell monitoring and compliance engine for Veritas NetBackup master and media server environments.

Designed for backup administrators and operations teams, this script performs an end-to-end audit across the entire backup infrastructure using an **exception-only model**—providing compact green passes for healthy components and generating structured alert tables only when anomalies, backlogs, or failures are detected.

---

## Key Features

* **Strictly Read-Only:** Zero state modifications, service restarts, or media commands. Safe for execution across production environments.
* **Single-Pass Architecture:** Collects CLI outputs (`bpdbjobs`, `nbdevquery`, `bpmedialist`, `bppllist`, `vmoprcmd`, `vmquery`, `nbcertcmd`) into memory in a single initial gathering pass (~5–8 seconds total runtime).
* **Multi-Domain & Path Auto-Discovery:** Dynamically discovers NetBackup installation drives (`D:\`, `N:\`, `C:\`, `E:\`), active robot number (`TLD 0`, `TLD 1`), and controlling media server hostnames.
* **Intelligent Job & Stream Classification:**
  * **Active Retry Suppression:** Suppresses failure alerts if a failed backup stream is currently being retried or is actively running.
  * **Partial Success Separation:** Isolates NetBackup Exit Code 1 (Partial Success) into an informational category, preventing it from being flagged as a complete failure.
  * **In-Progress Monthly Tracking:** Recognizes active, multi-day monthly backup jobs (such as large NDMP streams) and marks them as `[IN PROGRESS]` rather than falsely reporting them as missing.
* **Physical vs. Offsite Media Segregation:** Cross-references central media database records against the Volume Manager library inventory to distinguish between frozen tapes inside active tape libraries (TLDs) and historical tapes stored offsite/in vaults.
* **Deployment Policy Filtering:** Exempts client upgrade and deployment policies (`VxUpdate`, `NB_10.*`, `*upgrade*`) from silent policy and ghost client audits.

---

## Monitored Pillars

| Pillar | Command / Source | Evaluation & Alert Criteria |
| :--- | :--- | :--- |
| **Core Services** | `Get-Service NetBackup*` | Alerts if critical master daemons (`EMM`, `nbrb`, `bpdbm`, `bprd`) are stopped. |
| **Catalog Local Storage** | `Get-PSDrive` | Monitors free disk space on the drive hosting the NetBackup database (`NBDB`). Alerts at $\le 20\%$ (Warning) and $\le 10\%$ (Critical). |
| **Security Certificates** | `nbcertcmd -listCertDetails` | Multi-format parser evaluating days remaining. Alerts at $\le 60$ days (Warning) and $\le 30$ days (Critical). |
| **Catalog DR Freshness** | `bpimagelist -hoursago 48` | Verifies successful catalog backup (`Status 0`) within the last 24 hours. |
| **Storage Pools (MSDP/Cloud)**| `nbdevquery -listdv` | Evaluates PureDisk and Cloud storage pools against high-watermark utilization thresholds ($\ge 80\%$ Warning, $\ge 95\%$ Critical). |
| **Tape Drives** | `vmoprcmd -d` | Audits drive operational states (`UP`, `DOWN`, `AVR`, `NEEDS CLEANING`). |
| **Tape & Library Media** | `bpmedialist` & `vmquery` | Checks for frozen/suspended tapes inside the robot (TLD) and reports offsite frozen media; audits scratch pool inventory. |
| **Stalled Jobs Queue** | `bpdbjobs -report -all_columns` | Identifies active streams running longer than 24 hours (e.g., resource locks or stalled duplications). |
| **24h Backup Failures** | `bpdbjobs -report -all_columns` | Evaluates unresolved child stream failures (Exit Code $> 1$), filtering parent coordinator jobs (`-`) and benign exit code 191. |
| **Monthly Backup Schedules** | `bppllist` & `bpdbjobs` | Verifies successful completion within 31 days or reports active running status (`[IN PROGRESS]`). |
| **Silent Policies** | `bppllist` & `bpdbjobs` | Flags active policies that have generated 0 backup jobs across the past 14 days. |
| **Ghost Clients** | `bppllist` & `bpdbjobs` | Audits configured clients in active policies that have 0 successful backups across the past 30 days. |

---

## Prerequisites

* **Operating System:** Windows Server 2016, 2019, 2022, or 2025.
* **NetBackup Versions:** Veritas NetBackup 8.x, 9.x, 10.x.
* **PowerShell:** Windows PowerShell 5.1 or PowerShell 7+.
* **Execution Privileges:** Must be executed with administrative privileges on the Master/Primary Server.

---

## Usage

### Direct Execution via PowerShell Console
Open an elevated PowerShell console on the Master Server:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Get-NBUHealthDashboard.ps1
