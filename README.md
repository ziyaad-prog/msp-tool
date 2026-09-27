# MSP Tool

A WinUtil-style Windows toolkit for MSP technicians: 59 diagnostic, maintenance, security, repair and setup tools, runnable from a GUI, a console menu, or the command line (RMM / scripted).

Inspired by [Chris Titus Tech's WinUtil](https://github.com/christitustech/winutil).

## Features

- **GUI**: tools grouped in category tabs, with search, presets and procedures. Tools run in the background, so the window stays responsive and the log updates live. Tool prompts appear as dialog boxes. **Stop** (or closing the window) lets the running tool finish, including its cleanup such as restarting services it stopped, and then skips the rest.
- **Console menu**: the same tools as a text menu, for Server Core, plain RDP/SSH or remote PowerShell sessions.
- **CLI mode**: `-Preset`, `-Tools` or `-Procedure` for RMM and scripted runs.
- **Presets**: one-click bundles such as health checks, security audits, patching repair and ticket evidence.
- **Procedures**: step-by-step SOPs that mix automated tools with manual instructions.
- **Reports and logging**: reports go to `Desktop\MSP-Reports`, and every session is logged to `logs\`. **Report View** and **Ticket Bundle** collect them for a ConnectWise ticket.
- **One file per tool**: each tool is a plain `.ps1` in `tools\`, registered in `config\tools.json`.

## Requirements

- Windows 10/11 (Windows Server works for most tools)
- Windows PowerShell 5.1 (PowerShell 7 works for most tools)
- Administrator is recommended. Tools that need it are marked, and the entry scripts offer to relaunch elevated.

## Quick start

From the repo folder, double-click **`Start-MspTool.cmd`** (GUI) or **`Start-MspTool-Console.cmd`** (console menu), or run:

```powershell
.\msptool.ps1            # GUI
.\msptool-console.ps1    # console menu
```

In the console menu:

| Key | Action |
|---|---|
| a number, or a comma list (e.g. `1,3,5`) | toggle tools |
| `c` | switch category |
| `f` | set a search filter |
| `p` | apply a preset |
| `m` | run a procedure |
| `v` | view the selection |
| `r` | run the selection |
| `q` | quit |

## CLI usage

Both entry scripts accept the same flags:

```powershell
.\msptool.ps1 -ListTools
.\msptool.ps1 -ListPresets
.\msptool.ps1 -ListProcedures

.\msptool.ps1 -Preset QuickHealthCheck
.\msptool.ps1 -Tools MspDiagSystemInfo,MspDiagNetwork,MspSecDefenderStatus
.\msptool.ps1 -Procedure PerformanceTroubleshooting -AutoOnly      # automated steps only
.\msptool.ps1 -Procedure PerformanceTroubleshooting -Interactive   # confirm each step

# Options: -LogFile <path>  -NoTranscript
```

Some tools are interactive: they show a numbered list and ask what to do. In an unattended run, a blank answer always means the safe choice (exit, skip or no). Restart prompts default to **No**.

If an RMM agent (e.g. CWA) starts 32-bit PowerShell on 64-bit Windows, the entry scripts re-run themselves in 64-bit PowerShell automatically. They stay in the same console and return the same exit code; the session log records which bitness ran.

## Presets

| Preset | Tools |
|---|---|
| `QuickHealthCheck` | System info, network test, pending reboot, agent health, Defender, firewall, computer identity |
| `SecurityAudit` | Baseline scorecard, Defender, firewall, BitLocker, local admins, remote-access audit, failed logons, event logs |
| `FullMaintenance` | Restore point, temp cleanup, optimize drives, Windows Update status, Defender scan, event logs |
| `PatchingRepair` | Restore point, pending reboot, reset Windows Update components, DISM, SFC |
| `RepairBundle` | Restore point, DISM, SFC |
| `NewWorkstation` | Restore point, New Workstation Baseline, time sync, temp cleanup, Defender scan, Windows Update status |
| `TicketEvidence` | System info, event/reliability logs, shutdown history, pending reboot, then Ticket Bundle |
| `PerformanceTroubleshooting` | LENET performance SOP, automated tools only |
| `PerformanceSpecCheck` | Spec check, disk space, computer identity |
| `DomainHealthCheck` | Domain status, Entra/Intune status, network test |

Presets live in `config\presets.json`.

## Tools

The Admin column marks tools the engine skips unless MSP Tool is elevated. Tools without the mark may still ask for admin for their fix or change step.

<details>
<summary><b>Diagnostics</b> (11)</summary>

| Tool | Admin | What it does |
|---|---|---|
| Agent Health Check |  | Checks that the CWA, ScreenConnect, ImmyBot, Defender and third-party EDR/AV agents are installed and running (status, start type, version, CWA check-in), and offers to restart a stopped agent service (admin). |
| Battery Report |  | Battery charge, runtime, design vs full-charge capacity (health %) and cycle count, plus the Windows battery report as HTML. |
| Check Disk Health (SMART) |  | Disk health plus reliability counters (temperature, wear, power-on hours, errors) and SMART predictive failure. Full counters need admin. |
| Export Critical Event Logs & Reliability Report |  | System/Application errors (24h), a Reliability Monitor report (HTML + CSV, 30 days), and opens `perfmon /rel`. |
| Export System Information |  | OS, uptime, pending reboot, BIOS/serial, TPM, Secure Boot, Windows 11 readiness indicator, users, disks, network, installed software, `ipconfig /all`, `route print`. Saved as text and HTML. |
| Microsoft 365 Health |  | Office version and update channel, last update result, licensing and signed-in accounts, Outlook profiles and OST/PST sizes, and classic vs new Teams. |
| Network Connectivity Test |  | Ping/DNS, public IP, proxy, TCP port checks, Wi-Fi signal/band, and optional traceroute and WLAN report. |
| Pending Reboot Check |  | Standard pending-reboot indicators, uptime, and a restart offer (default no) only if a reboot is pending. |
| Report View |  | Lists saved reports and logs to view or open, bundles them for a ticket, and deletes old reports. |
| Ticket Bundle |  | Zips recent reports and logs with a summary into `ticket-<COMPUTER>-<date>.zip`. |
| Unexpected Shutdown History |  | 30-day timeline of unexpected shutdowns, dirty reboots, BSODs (bugcheck codes) and restarts. |

</details>

<details>
<summary><b>Domain</b> (10)</summary>

| Tool | Admin | What it does |
|---|---|---|
| Domain Join Status |  | Domain membership and secure channel health. |
| Entra ID / Intune Join Status |  | `dsregcmd /status` summary (Entra/hybrid join, PRT, device certificate, MDM), Intune enrollment and hints. |
| VPN Checker |  | Lists VPN connections and starts one. |
| Test Domain Join Credential |  | Checks that a credential authenticates to the target domain. |
| Repair Domain Secure Channel | Yes | Tests and repairs the machine trust ("trust relationship failed"). |
| Remove Workstation from Domain | Yes | Unjoins to a workgroup. |
| Join Workstation to Domain | Yes | Checks connectivity and joins a domain (optional OU). |
| Force Group Policy Update | Yes | `gpupdate /force` and `gpresult /r`. |
| Domain Connectivity Test |  | DNS, DC discovery and LDAP 389, with an option to start a VPN and retest. |
| Start VPN Connection |  | Starts a VPN, then offers a domain connectivity retest. |

</details>

<details>
<summary><b>Maintenance</b> (4)</summary>

| Tool | Admin | What it does |
|---|---|---|
| Check Windows Update Status | Yes | Pending updates (installs the PSWindowsUpdate module if missing). |
| Clear Temp Files | Yes | Temp and browser cache files older than 7 days, all users (never cookies, history or passwords). Per-folder summary. Reports the Windows.old size. |
| Optimize Drives | Yes | Defrag/TRIM all fixed drives. |
| Run Disk Cleanup | Yes | Runs cleanmgr. |

</details>

<details>
<summary><b>Performance</b> (11)</summary>

| Tool | Admin | What it does |
|---|---|---|
| Audit Non-Microsoft Services |  | Running non-Microsoft services, with disable / set to manual. |
| Audit Startup Applications | Yes | Registry and Startup-folder entries, with removal. |
| Check Disk Free Space |  | Warns below 20% free. |
| Clear User Temp Folder (%temp%) |  | Clears the current user's %temp%. |
| CPU & Memory Snapshot |  | Current CPU and memory usage. |
| DISM Full Sequence (scan/check/restore) | Yes | DISM scanhealth, checkhealth and restorehealth. |
| LENET Spec Recommendation Check |  | SSD/HDD, RAM, CPU and age against the LENET Techno Stack. |
| Manufacturer Support & Driver Tools |  | Serial number plus Dell/HP/Lenovo support links. |
| Open Resource Monitor |  | Launches resmon. |
| Recent Windows Updates (30 days) |  | Lists recent updates. Uninstall one (DISM), or reinstall one this tool removed (Windows Update). |
| Top CPU & Memory Processes |  | Top 10 processes by CPU and by memory. |

</details>

<details>
<summary><b>Repair</b> (9)</summary>

| Tool | Admin | What it does |
|---|---|---|
| Clear Teams / Outlook Cache |  | Clears Teams and Outlook caches for the current user (OST/PST never touched). |
| DISM Health Restore | Yes | `DISM /RestoreHealth`. |
| OneDrive Reset |  | Restarts or resets OneDrive for the current user (files are not deleted). |
| Printer Troubleshooter |  | Printers, queues and spooler: clear stuck jobs, restart the spooler, print a test page, set the default. |
| Quick Network Fix |  | Flush DNS, release/renew DHCP, register DNS, then retest. |
| Rebuild Search Index | Yes | Restarts Windows Search. |
| Reset Network Stack | Yes | Winsock and IP reset (reboot needed). |
| Reset Windows Update Components | Yes | Stops the update services, renames SoftwareDistribution and catroot2 (never deletes), and restarts the services. |
| System File Checker (SFC) | Yes | `sfc /scannow`. |

</details>

<details>
<summary><b>Security</b> (8)</summary>

| Tool | Admin | What it does |
|---|---|---|
| Audit Local Administrators | Yes | Admin group members vs an allow-list, built-in Administrator state, LAPS status, and a password reset option. |
| BitLocker Status | Yes | Encryption status, method and protectors, and whether the recovery key was backed up. Never shows recovery passwords. |
| Defender Status Report |  | Protection state, tamper protection, signature age, recent detections and exclusions. |
| Failed Logons & Lockouts | Yes | Failed logons, lockouts and RDP logons, with brute-force and password-spray flags. |
| Firewall Profile Status |  | Domain, Private and Public profile state. |
| Remote Access Software Audit |  | Finds AnyDesk, TeamViewer, RustDesk, extra ScreenConnect instances and similar tools; marks each approved or unapproved. |
| Security Baseline Scorecard |  | PASS/WARN/FAIL scorecard (SMBv1, RDP/NLA, UAC, Secure Boot, TPM, BitLocker, LLMNR, password policy and more), with an HTML copy. |
| Windows Defender Quick Scan | Yes | Starts a quick scan. |

</details>

<details>
<summary><b>Setup</b> (6)</summary>

| Tool | Admin | What it does |
|---|---|---|
| Create Restore Point | Yes | Creates a restore point before changes. |
| Enable Remote Desktop | Yes | Enables RDP and its firewall rule. |
| Force Time Sync | Yes | Restarts w32time and resyncs. |
| New Workstation Baseline | Yes | Rename, time zone, power plan, remove consumer apps, install baseline apps with winget. Each step is confirmed. Settings are in `config\baseline.json`. |
| Set Balanced Power Plan |  | Activates Balanced. |
| Show Computer Identity |  | Hostname, domain/workgroup, make/model and serial. |

</details>

### Standalone: `Join-MspDomain.ps1`

An interactive domain join/repair script covering status, secure channel test and repair, join (optional OU/rename), connectivity test and unjoin:

```powershell
.\Join-MspDomain.ps1 [-Domain corp.contoso.com] [-OU "OU=Workstations,DC=corp,DC=contoso,DC=com"] [-ComputerName NEWNAME] [-StatusOnly] [-NoRestart]
```

## Where output goes

| What | Where |
|---|---|
| Reports (system info, reliability, battery, security scorecard, CSV exports, ticket zips) | `Desktop\MSP-Reports\` of the user running the tool |
| Session logs and transcripts | `logs\` in the MSP Tool folder |
| Updates removed by *Recent Windows Updates* (used for reinstall) | `C:\ProgramData\MSP-Tool\uninstalled-updates.json` |

Logs record tool output. Tools never print secrets such as recovery keys, LAPS passwords or tokens.

## Configuration

- **`config\tools.json`**: tool registry (name, description, category, admin flag, script path).
- **`config\presets.json`**: preset bundles.
- **`config\procedures\*.json`**: step-by-step procedures. Each step has `Type` `tool` (with a `ToolId`) or `manual` (with `Instructions`).
- **`config\baseline.json`**: New Workstation Baseline settings: default time zone, power plan, apps to remove, and winget apps to install. **The InstallApps list is an example; replace it with your standard apps.**
- **Settings at the top of individual tools**: tunable lists sit in clearly named variables at the top of each tool file. Examples:
  - `tools\MspSecRemoteAccessAudit.ps1`: `$approvedNames` / `$approvedScreenConnectIds`. Add your ScreenConnect instance ID so foreign instances are flagged.
  - `tools\MspDiagAgentHealth.ps1`: agent and EDR service names.
  - `tools\MspSecLocalAdmins.ps1`: `$extraAllowedAdmins`.
  - `tools\MspMaintTempCleanup.ps1`: `$minAgeDays`.
  - `tools\MspSecBaseline.ps1`: OS support table.

## Adding a tool

1. Create `tools\MyTool.ps1`. The file is the body of a script block, not a script:
   - no `param()` block
   - `return` to stop early
   - print with `Write-Host`
   - `$ErrorActionPreference` is `Stop`, so a native command (`net`, `rasdial`, and so on) that writes to stderr would abort the tool. Run native commands like this: `& { $ErrorActionPreference = 'Continue'; net ... 2>&1 }`
2. Register it in `config\tools.json`:

   ```json
   "MyTool": {
     "Content": "My Custom Action",
     "Description": "Does something useful.",
     "category": "Maintenance",
     "RequiresAdmin": true,
     "Script": "tools/MyTool.ps1"
   }
   ```

   Optional: `"Order": 1` sorts tools within a category. Inline `"InvokeScript": ["..."]` still works for small custom tools.
3. For interactive tools:
   - Print the list before calling `Read-Host`, and make a blank answer mean exit or no.
   - Ask for a typed `YES` before anything destructive.
   - Never restart automatically.

   `Read-Host` and `Get-Credential` work in all three front-ends; the GUI shows them as dialogs.
4. Run the tests.

## Tests

```powershell
# Static and engine checks (no tools are run): parsing, config validity, references, engine behaviour, list commands
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MspTool.ps1

# Optional GUI end-to-end test (opens a window for ~30 s; uses harmless fake tools and UI Automation)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MspGui.ps1
```

Both exit with the number of failed checks. They don't need Pester; Windows only ships Pester 3.4.

## Project structure

```
msp-tool/
├── msptool.ps1                  # Entry point (GUI; also CLI flags)
├── msptool-console.ps1          # Entry point (console menu; also CLI flags)
├── Start-MspTool.cmd            # Double-click launchers
├── Start-MspTool-Console.cmd
├── Join-MspDomain.ps1           # Standalone domain join/repair script
├── config/
│   ├── tools.json               # Tool registry
│   ├── presets.json             # Preset bundles
│   ├── baseline.json            # New Workstation Baseline settings
│   └── procedures/              # Step-by-step procedures
├── functions/
│   ├── Invoke-MspTool.ps1       # Tool engine
│   ├── Invoke-MspProcedure.ps1  # Procedure runner
│   ├── Show-MspGui.ps1          # WPF GUI (background runner, input dialogs)
│   └── Show-MspConsoleMenu.ps1  # Console menu
├── tools/                       # One .ps1 per tool
└── tests/
    ├── Test-MspTool.ps1         # Test suite
    ├── Test-MspGui.ps1          # GUI end-to-end test
    └── gui-test-host.ps1        # Helper for the GUI test
```

## License

MIT
