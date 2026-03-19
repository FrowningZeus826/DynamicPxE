# Dell Image Assist - WinPE Deployment Tool

**Built by:** Spireworks  
**Platform:** Windows ADK 26100 · Windows 11 24H2 / 25H2  
**Target hardware:** Dell (Latitude, OptiPlex, Precision, Vostro, XPS)  
**Architecture:** x64 only  
**License:** MIT

---

## What This Is

A fully custom WinPE boot environment that replaces manual imaging with a dark-themed GUI. A technician boots a Dell machine via PXE, the GUI loads automatically, detects the hardware model, auto-selects the correct Win11 driver pack from the network share, and walks the technician through selecting an OS image and starting deployment. The entire pipeline runs unattended after confirmation - disk partition, image apply, driver injection, boot configuration, and reboot.

This fills the gap left by Microsoft discontinuing MDT support for Windows 11 24H2. It is not a wrapper around MDT or SCCM - every component is purpose-built PowerShell with no external tooling dependencies beyond the Windows ADK.

---

## Features

- **Auto hardware detection** - WMI queries the Dell model at boot, no technician input needed
- **Driver auto-matching** - scores every ZIP on the share against the detected model, selects the best match automatically
- **Dell Image Assist WIM support** - auto-detects the 5-index Dell IA WIM structure and applies index 2 (Windows_IW)
- **Fully configurable** - `DeployConfig.json` controls share path, branding, colors, timezone, and more
- **Custom branding** - logo (PNG) and icon (ICO) loaded from `Resources\` at runtime
- **Secure Boot compatible** - built with ADK 26100, signed for current Dell UEFI firmware
- **Auto-reboot** - machine boots directly to the new OS after deployment, no F12 needed
- **Deployment log** - full timestamped log copied to `C:\Deploy_Log.txt` on the deployed OS
- **Repair tool** - `Repair-Build.ps1` cleans stale DISM mounts when builds fail

---

## Repository Layout

```
DynamicPxE/
├── Build-WinPE.ps1                 # ADK build script - produces boot.wim
├── Repair-Build.ps1                # Cleans stale mounts after a failed build
├── startnet.cmd                    # Injected into WIM - launches GUI at WinPE boot
├── LICENSE
├── .gitignore
│
├── Config/
│   ├── DeployConfig.example.json   # Template - copy to DeployConfig.json
│   └── DellDriverMap.example.json  # Template - copy to DellDriverMap.json
│
├── Resources/                      # Branding assets (not included - add your own)
│   └── README.txt                  # Instructions for logo.png and icon.ico
│
├── Scripts/
│   ├── Core/
│   │   ├── Apply-Image.ps1         # Disk partitioning + DISM apply + BCDboot
│   │   ├── Expand-DriverPack.ps1   # Extracts driver ZIPs to OS disk before injection
│   │   ├── Inject-Drivers.ps1      # Offline DISM driver injection into applied OS
│   │   ├── Invoke-Deployment.ps1   # Orchestrator - chains all deployment steps
│   │   └── Map-NetworkShare.ps1    # Authenticates and maps the deployment share
│   ├── Dell/
│   │   ├── Get-DellModel.ps1       # WMI hardware detection
│   │   └── Get-DellDriverPack.ps1  # Driver pack scoring and auto-match engine
│   ├── GUI/
│   │   └── Start-DeployGUI.ps1     # WinForms GUI - two-column landscape layout
│   └── Logging/
│       └── Write-DeployLog.ps1     # Structured timestamped logging
│
└── Docs/
    ├── Deployment.md               # Full step-by-step build and deployment guide
    └── Reference.md                # Script API, architecture, troubleshooting
```

---

## Quick Start

Full instructions are in `Docs/Deployment.md`. In brief:

**1. Prerequisites**
- Windows ADK 26100 (Deployment Tools only)
- WinPE Add-on for ADK 26100
- Dell WinPE 11 Driver Pack (CAB file from Dell support)

**2. Set up the project folder**
```powershell
mkdir C:\DynamicPxE
# Copy all repo files into C:\DynamicPxE\
# Extract Dell WinPE CAB into C:\DynamicPxE\DellWinPEDrivers\
expand.exe -F:* "WinPE11.0-Drivers-A01.cab" C:\DynamicPxE\DellWinPEDrivers
```

**3. Configure your environment**

Both config files are excluded from the repo. Copy the example files and fill in your settings:
```powershell
Copy-Item Config\DeployConfig.example.json  Config\DeployConfig.json
Copy-Item Config\DellDriverMap.example.json Config\DellDriverMap.json
```

Then edit `Config\DeployConfig.json` with your share path and org settings:
```json
"Network": {
    "ShareRoot": "\\\\your-server\\your-share",
    "DriveLetter": "Z:"
}
```

**4. Add branding (optional)**

Drop `logo.png` and `icon.ico` into `Resources\` and update the paths in `DeployConfig.json`.

**5. Build**
```powershell
cd C:\DynamicPxE
.\Build-WinPE.ps1
```

**6. Deploy**
- Upload `boot.wim` to WDS → Boot Images → Add Boot Image
- Place OS WIM files in your share's `Images\` folder
- Place Dell driver ZIPs in your share's `Drivers\` folder
- PXE boot a Dell machine

---

## Configuration

All settings live in `Config\DeployConfig.json`. Key sections:

| Section | Key settings |
|---|---|
| `Network` | Share UNC path, drive letter, Images/Drivers subfolder names |
| `App` | Window title, version, org name, build label, domain prefix |
| `Deployment` | Default image index, target disk, timezone, reboot countdown |
| `Branding` | Logo path, icon path, accent color RGB |

---

## Network Share Layout

```
\\your-server\your-share\
├── Images\
│   └── *.wim  (Dell Image Assist or standard WIM files)
└── Drivers\
    └── *.zip  (Dell driver packs in standard naming format)
```

Driver packs use Dell's standard ZIP naming: `{os}_{familytoken}_{revision}.zip`  
Example: `win11_latitudee14mlk5530_a16.zip`

No pre-extraction needed - the system extracts ZIPs to the OS disk at deploy time and cleans up automatically.

---

## Driver Auto-Matching

When the share connects, every ZIP is scored against the detected WMI model string:

1. **Model score** - 4-digit model number match against ZIP filename token
2. **OS preference** - `win11_*` beats `win10_*` at equal score
3. **Revision** - higher `a` number wins at equal score

The auto-matched pack is highlighted and pre-selected. Technicians can override by selecting any pack from the list.

`DellDriverMap.json` handles edge cases where auto-scoring picks the wrong pack (e.g. two win11 packs with identical scores). Add an entry to pin a specific ZIP to a specific model key.

---

## Dell Image Assist WIM Structure

Dell Image Assist captures produce 5-index WIMs. Only index 2 is deployable:

| Index | Description | Deploy? |
|---|---|---|
| 1 | System - Dell IA metadata | No |
| 2 | Windows_IW - the OS | **Yes** |
| 3 | Recovery - placeholder | No |
| 4 | Summary_IA - metadata | No |
| 5 | Logs - capture logs | No |

The GUI auto-detects this structure and sets the index field to 2 automatically.

---

## Deployment Pipeline

```
PXE boot → WinPE loads → GUI launches
    ↓
Enter share credentials → share mapped to Z:\
    ↓
Hardware detected → driver pack auto-matched → image selected → confirm
    ↓
1. diskpart   - GPT: EFI(260MB) + MSR(16MB) + OS + Recovery(650MB)
2. Expand     - driver ZIP extracted to W:\DriverTemp\
3. DISM       - OS image applied to W:\ (index 2 for Dell IA WIMs)
4. DISM       - drivers injected offline into W:\
5. BCDboot    - UEFI boot configured on EFI partition
6. bcdedit    - one-time boot sequence set to Windows Boot Manager
7. Cleanup    - driver temp removed, Deploy_Info.json written to W:\
8. Log copy   - deploy.log copied to W:\Deploy_Log.txt
9. Reboot     - 15-second countdown, machine boots to new OS
```

---

## Extending for Other Manufacturers

The architecture supports multi-vendor expansion:

- Add `Scripts/Lenovo/Get-LenovoModel.ps1`
- Add `Scripts/Lenovo/Get-LenovoDriverPack.ps1`
- Uncomment the `# FUTURE: Lenovo` branch in `Invoke-Deployment.ps1`

The GUI, core imaging scripts, and build script require no changes.

---

## Troubleshooting

**Build fails at step 3** - stale DISM mount. Run `.\Repair-Build.ps1` then rebuild.

**GUI shows `\\server\share`** - `DeployConfig.json` not in the WIM. Verify the file is in `Config\` before building.

**DISM apply fails (exit 123)** - invalid path. Ensure the share is accessible and `ShareRoot` in config is correct.

**Drivers not injecting** - driver ZIP too large for RAM disk. Fixed in current version - extracts to `W:\DriverTemp\` on the OS disk instead.

**Machine doesn't auto-boot to SSD** - `bcdedit` boot sequence. Fixed in current version.

**Full deployment log** - available at `C:\Deploy_Log.txt` on the deployed OS after first boot.

---

## Requirements

| Component | Requirement |
|---|---|
| Build machine | Windows 10/11 x64, Administrator access |
| ADK | Windows ADK 26100 (Deployment Tools) |
| WinPE Add-on | ADK 26100 WinPE Add-on |
| Dell WinPE Drivers | Dell WinPE 11 Driver Pack (CAB) |
| Network share | SMB share accessible from WinPE |
| Target machines | Dell x64 hardware, UEFI, Secure Boot optional |
| WDS/PXE | Any WDS server or PXE environment |
