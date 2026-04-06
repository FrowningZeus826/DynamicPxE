# DynamicPxE — WinPE Zero-Touch Deployment Tool

**Platform:** Windows ADK 26100 · Windows 11 24H2 / 25H2
**Target hardware:** Any x64 hardware — Dell, Lenovo, HP, and generic
**Architecture:** x64 only
**License:** MIT

---

## What This Is

A fully custom WinPE live boot environment for zero-touch Windows deployment using stock Microsoft `install.wim` files. No custom images, no capture workflows, no MDT.

PXE boot any machine, connect to a network share, pick an OS image and driver pack, and walk away. DynamicPxE handles everything: disk partitioning, image apply, driver injection, unattend.xml generation (computer naming, domain join, product key, locale, OOBE bypass), and a `SetupComplete.cmd` that installs apps from a network share after first boot.

This fills the gap left by Microsoft discontinuing MDT support for Windows 11 24H2. Every component is purpose-built PowerShell with no external tooling dependencies beyond Windows ADK.

---

## Features

### Deploy Wizard
- **4-page GUI** — Connect → Select → Configure → Deploy, with sidebar step tracking and back/next navigation
- **Auto hardware detection** — WMI queries model at boot (Dell, Lenovo, HP, generic) with service tag
- **Driver auto-matching** — 5-point scoring against ZIP filenames on the share; works with Dell, Lenovo SCCM, HP SoftPaq, and custom naming
- **Stock WIM support** — uses `install.wim` directly from Microsoft ISOs (index 1)
- **Fully configurable** — `DeployConfig.json` controls everything: share paths, branding, deployment settings, app installs

### Zero-Touch Configuration
- **unattend.xml generation** — built dynamically at deploy time with:
  - Computer naming from templates (`%SERVICETAG%`, `%MODEL%`, `%VENDOR%`)
  - Active Directory domain join with OU targeting (uses share credentials)
  - MAK product key activation
  - Timezone, locale, and input settings
  - Full OOBE bypass (EULA, online account, wireless setup, OEM registration)
  - Windows 11 BypassNRO (skips mandatory Microsoft account)
  - Local admin account creation with auto-logon for SetupComplete.cmd
- **SetupComplete.cmd generation** — config-driven post-setup automation:
  - App installation from a network share (public, no credentials)
  - Per-app success/failure logging to `C:\DynamicPxE\Logs\SetupComplete.log`
  - WiFi profile import (auto-connect when ethernet unavailable)
- **Config-driven defaults** — all settings come from `DeployConfig.json` but are editable in the GUI at boot time

### GUI Framework
- **Theme engine** — configurable dark theme with hex color palette, DPI-aware scaling, font registry
- **Custom controls** — owner-drawn rounded buttons with hover animations, gradient progress bars, styled textboxes and listboxes, toast notifications
- **Page manager** — wizard state machine with sidebar step indicators (numbered circles, checkmarks for completed steps)
- **Animation engine** — timer-based smooth color transitions and cubic ease-out slide animations
- **Layout helpers** — card panels with borders, form rows, full-width rows, section headers, spacer panels

### Operations
- **Sidebar lock** — sidebar navigation disabled during active deployment to prevent accidental page switches
- **Background deployment** — runs in a separate runspace so the GUI stays responsive during long DISM operations
- **Deployment log** — full timestamped log viewable in the GUI and written to the deployed OS
- **Custom branding** — logo (PNG) and icon (ICO) loaded from `Resources\` at runtime
- **Repair tool** — `Repair-Build.ps1` cleans stale DISM mounts when builds fail

---

## Repository Layout

```
DynamicPxE/
├── Build-WinPE.ps1                   # ADK build script — produces boot.wim
├── Repair-Build.ps1                  # Cleans stale mounts after a failed build
├── startnet.cmd                      # Injected into WIM — launches deploy GUI at boot
├── LICENSE
├── .gitignore
│
├── Config/
│   ├── DeployConfig.example.json     # Template - copy to DeployConfig.json
│   └── DriverMap.example.json        # Template - copy to DriverMap.json
│
├── Resources/                        # Branding assets (not included - add your own)
│   └── README.txt                    # Instructions for logo.png and icon.ico
│
├── Scripts/
│   ├── Core/
│   │   ├── Apply-Image.ps1           # Disk partitioning + DISM apply + BCDboot
│   │   ├── Expand-DriverPack.ps1     # Extracts driver ZIPs to OS disk before injection
│   │   ├── Inject-Drivers.ps1        # Offline DISM driver injection into applied OS
│   │   ├── Invoke-Deployment.ps1     # Orchestrator — chains all steps + generates unattend/SetupComplete
│   │   └── Map-NetworkShare.ps1      # Authenticates and maps the deployment share
│   ├── Hardware/
│   │   ├── Get-HardwareModel.ps1     # WMI hardware detection — multi-vendor
│   │   └── Get-DriverPack.ps1        # Driver pack scoring and auto-match — vendor-agnostic
│   ├── GUI/
│   │   ├── Start-DeployGUI.ps1       # Deploy wizard — 4-page sidebar layout
│   │   └── Framework/
│   │       ├── Initialize-GUIFramework.ps1  # Master loader — dot-source this one file
│   │       ├── ThemeEngine.ps1        # Color palette, fonts, DPI scaling
│   │       ├── LayoutHelpers.ps1      # App shell, card panels, form rows
│   │       ├── AnimationEngine.ps1    # Hover transitions, slide animations
│   │       ├── CustomControls.ps1     # Rounded buttons, progress bars, toast notifications
│   │       └── PageManager.ps1        # Wizard page state machine + sidebar steps
│   └── Logging/
│       └── Write-DeployLog.ps1       # Structured timestamped logging
│
└── Docs/
    ├── Deployment.md                 # Full step-by-step build and deployment guide
    └── Reference.md                  # Script API, architecture, troubleshooting
```

---

## Quick Start

Full instructions are in `Docs/Deployment.md`. In brief:

**1. Prerequisites**
- Windows ADK 26100 (Deployment Tools only)
- WinPE Add-on for ADK 26100
- Vendor WinPE driver CAB (Dell, Lenovo, HP — from your vendor's support site)

**2. Set up the project folder**
```powershell
mkdir C:\DynamicPxE
# Copy all repo files into C:\DynamicPxE\

# Extract your WinPE driver CAB into WinPEDrivers\
# Dell example:
expand.exe -F:* "WinPE11.0-Drivers-A01.cab" C:\DynamicPxE\WinPEDrivers
```

**3. Configure your environment**
```powershell
Copy-Item Config\DeployConfig.example.json  Config\DeployConfig.json
Copy-Item Config\DriverMap.example.json     Config\DriverMap.json
```

Edit `Config\DeployConfig.json` — at minimum set your share paths:
```json
{
  "Network": {
    "ShareRoot": "\\\\your-server\\deploy-share"
  },
  "Deployment": {
    "ComputerNameTemplate": "PC-%SERVICETAG%",
    "DomainName": "corp.example.com",
    "DomainOU": "OU=Workstations,DC=corp,DC=example,DC=com"
  },
  "Apps": {
    "SharePath": "\\\\your-server\\apps-share",
    "Packages": [
      { "Name": "Chrome", "Path": "Chrome\\GoogleChromeStandaloneEnterprise64.msi", "Args": "/qn /norestart" }
    ]
  }
}
```

**4. Build**
```powershell
cd C:\DynamicPxE
.\Build-WinPE.ps1
```

**5. Deploy**
- Upload `boot.wim` to WDS → Boot Images → Add Boot Image
- Place stock `install.wim` files in your share's `Images\` folder
- Place driver ZIPs in your share's `Drivers\` folder
- PXE boot a machine — the deploy wizard launches automatically

---

## Configuration

### DeployConfig.json

| Section | Key settings |
|---|---|
| `Network` | Share UNC path, drive letter, Images/Drivers subfolder names |
| `App` | Window title, version, org name, build label, domain prefix |
| `Deployment` | Computer name template, domain/OU, product key, timezone, locale, WiFi, image index, target disk |
| `Apps` | App share path, drive letter, packages array (Name, Path, Args) |
| `Theme.Colors` | Hex color overrides for all palette entries (Background, Surface, Accent, etc.) |
| `Theme.Fonts` | Font family, sizes for body/heading/title/small/mono |
| `Theme` | AnimationsEnabled (bool), CornerRadius (int) |
| `Branding` | Logo path, icon path |

### Configure Page (GUI)

All deployment settings from the config file are editable at boot time in the GUI:

| Card | Editable fields |
|---|---|
| Deployment Options | Target disk, image index |
| OS Configuration | Computer name template, domain, OU, product key, timezone |
| WiFi | SSID, password |
| Post-Setup Apps | Read-only display of configured app installs |

---

## Network Share Layout

```
Deploy Share (\\your-server\deploy-share):
├── Images\
│   ├── Win11_24H2_Enterprise_x64.wim    (stock install.wim from ISO)
│   └── Win11_23H2_Pro_x64.wim
└── Drivers\
    ├── win11_latitude5550_a19.zip        (Dell)
    ├── lenovo_thinkpadx1carbon_win11.zip (Lenovo)
    └── hp_elitebook840g10_win11.zip      (HP)

App Share (\\your-server\apps-share):     (public, no credentials)
├── Chrome\
│   └── GoogleChromeStandaloneEnterprise64.msi
├── AdobeReader\
│   └── AcroRdrDC_en_US.exe
└── 7-Zip\
    └── 7z2409-x64.msi
```

---

## Deployment Pipeline

```
PXE boot -> WinPE loads -> Deploy wizard launches automatically
    |
Page 1: Connect -> credentials + share mapping
    |
Page 2: Select -> image list + driver list (auto-selected for detected hardware)
    |
Page 3: Configure -> deployment options, OS config, WiFi, apps display
    |
Confirm dialog -> Page 4: Deploy (sidebar locked)
    |
 1. diskpart    -- GPT: EFI(260MB) + MSR(16MB) + OS + Recovery(650MB)
 2. DISM        -- stock install.wim applied to W:\
 3. ZIP extract -- driver pack extracted to W:\DriverTemp\
 4. DISM        -- drivers injected offline into W:\
 5. unattend    -- generated and written to W:\Windows\Panther\unattend.xml
 6. SetupComplete -- generated: WiFi import + app installs from network share
 7. BCDboot     -- UEFI boot configured on EFI partition
 8. Cleanup     -- Deploy_Info.json written, log saved
 9. Reboot      -- machine boots to new OS -> zero-touch OOBE
```

**After reboot**, Windows processes the unattend.xml (domain join, naming, licensing, OOBE bypass, local admin creation) and runs SetupComplete.cmd (WiFi profile import, app installs with logging).

---

## Driver Auto-Matching

When the network share connects, every ZIP is scored against the detected WMI model string. The best match (score >= 3) is automatically selected.

1. **JSON override** — `DriverMap.json` pins specific ZIPs to specific model keys (escape hatch)
2. **Model number** — 4-digit model number match against ZIP filename token (most reliable)
3. **OS preference** — `win11_*` beats `win10_*` at equal score
4. **Revision** — higher `a` number wins at equal score

Supports Dell, Lenovo, HP, and any custom ZIP naming that includes the model string.

---

## Testing the GUI Locally

You can test the GUI on a regular Windows machine without rebuilding the WIM:

```powershell
# From the repo root on your Windows machine:
. .\Scripts\Logging\Write-DeployLog.ps1
. .\Scripts\GUI\Framework\Initialize-GUIFramework.ps1
. .\Scripts\GUI\Start-DeployGUI.ps1
```

What works locally: all visual rendering, page navigation, sidebar, animations, theming, DPI scaling.
What will error: network share mapping, `X:\Deploy\` paths, diskpart/DISM commands (don't click Deploy).

---

## Troubleshooting

**Build fails at step 3** — stale DISM mount. Run `.\Repair-Build.ps1` then rebuild.

**GUI shows `\\server\share`** — `DeployConfig.json` not in the WIM. Verify the file is in `Config\` before building.

**DISM apply fails** — verify the share is accessible and `ShareRoot` in config is correct. Check `X:\Windows\Logs\DISM\dism.log`.

**Drivers not injecting** — driver ZIP too large for RAM disk. Current version extracts to `W:\DriverTemp\` on the OS disk.

**Driver not auto-selected** — scoring engine requires match score >= 3. Check the deployment log. Add an override in `DriverMap.json` if needed.

**Domain join fails** — verify the domain name and credentials. The share credentials are reused for domain join. The username must not include a domain prefix (e.g. use `svc-deploy`, not `DOMAIN\svc-deploy`). Check `C:\Windows\debug\NetSetup.LOG` on the deployed OS.

**Apps not installing** — check `C:\DynamicPxE\Logs\SetupComplete.log` on the deployed OS. Verify the app share is accessible (public, no auth) and paths in config are correct.

**Full deployment log** — available at `C:\Deploy_Log.txt` on the deployed OS after first boot.

---

## Requirements

| Component | Requirement |
|---|---|
| Build machine | Windows 10/11 x64, Administrator access |
| ADK | Windows ADK 26100 (Deployment Tools) |
| WinPE Add-on | ADK 26100 WinPE Add-on |
| WinPE Drivers | Vendor WinPE driver CAB extracted to `WinPEDrivers\` |
| Deploy share | SMB share accessible from WinPE (credentials prompted) |
| App share | SMB share accessible from deployed OS (public, no credentials) |
| OS images | Stock `install.wim` from Microsoft Windows ISO |
| Target machines | x64 hardware, UEFI, Secure Boot optional |
| WDS/PXE | Any WDS server or PXE environment |
