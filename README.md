# MSP Tool

A WinUtil-style Windows utility for MSP technicians. Select tools from a categorized GUI, apply presets for common workflows, or run headless from the command line.

Inspired by [Chris Titus Tech's WinUtil](https://github.com/christitustech/winutil).

## Features

- **Checkbox GUI** — Browse tools by category (Diagnostics, Maintenance, Security, Repair, Setup)
- **Console menu** — Same tool engine, no WPF: a text menu for sessions with no desktop (Server Core, plain RDP/SSH)
- **Presets** — One-click bundles for health checks, maintenance, security audits, and more
- **Search** — Filter tools by name or description
- **CLI mode** — Automate with `-Preset` or `-Tools` for RMM/scripted deployments
- **JSON config** — Add or customize tools without changing the UI code

## Quick Start

Open **PowerShell as Administrator** (recommended for full tool access), then:

```powershell
cd C:\Users\LENET\Projects\msp-tool
.\msptool.ps1
```

### Console edition

`msptool.ps1` opens a WPF GUI, which needs a desktop session. `msptool-console.ps1` is a
separate, fully text-based entry point that drives the exact same `config/tools.json` /
`config/presets.json` engine through a numbered menu instead — useful over a plain
SSH/PS-remoting session or on Server Core:

```powershell
.\msptool-console.ps1
```

In the menu: type a tool's number (or a comma-separated list, e.g. `1,3,5`) to toggle it,
`c` to switch category, `f` to set a search filter, `p` to apply a preset, `m` to run a
procedure, `v` to view your current selection, `r` to run it, and `q` to quit. It accepts
the same `-Preset`, `-Tools`, `-Procedure`, `-ListTools`, `-ListPresets`, `-ListProcedures`
flags as `msptool.ps1` for headless/RMM use.

## CLI Usage

```powershell
# List available tools
.\msptool.ps1 -ListTools

# List presets
.\msptool.ps1 -ListPresets

# Run a preset
.\msptool.ps1 -Preset QuickHealthCheck

# Run specific tools
.\msptool.ps1 -Tools MspDiagSystemInfo, MspDiagNetwork, MspSecDefenderStatus
```

## Presets

| Preset | Description |
|--------|-------------|
| `QuickHealthCheck` | Fast diagnostic snapshot for triage |
| `FullMaintenance` | Monthly maintenance bundle |
| `SecurityAudit` | Security posture review |
| `RepairBundle` | DISM + SFC repair sequence |
| `NewWorkstation` | Baseline setup for new machines |

## Adding Tools

Edit `config/tools.json`. Each tool supports:

| Field | Description |
|-------|-------------|
| `Content` | Display name |
| `Description` | Tooltip / help text |
| `category` | Tab grouping |
| `RequiresAdmin` | Skip if not elevated |
| `InvokeScript` | Array of PowerShell script strings to run |

Example:

```json
"MyCustomTool": {
  "Content": "My Custom Action",
  "Description": "Does something useful.",
  "category": "Maintenance",
  "RequiresAdmin": true,
  "InvokeScript": [
    "Write-Host 'Hello from my tool'"
  ]
}
```

Add the tool ID to a preset in `config/presets.json` to include it in a bundle.

## Project Structure

```
msp-tool/
├── msptool.ps1               # Entry point (WPF GUI)
├── msptool-console.ps1       # Entry point (console menu, no WPF)
├── config/
│   ├── tools.json            # Tool definitions
│   └── presets.json          # Preset bundles
└── functions/
    ├── Invoke-MspTool.ps1    # Tool execution engine
    ├── Show-MspGui.ps1       # WPF GUI
    └── Show-MspConsoleMenu.ps1 # Console menu
```

## Requirements

- Windows 10/11
- PowerShell 5.1 or PowerShell 7+
- Administrator recommended (some tools require elevation)

## License

MIT
