# DynamicPxE — Technical Reference

This document covers the internals of every component: what each script does, what it expects, what it returns, and how the pieces connect. For step-by-step build and deployment instructions, see `Deployment.md`.

---

## 1. System Architecture

```
startnet.cmd
    └── Start-DeployGUI.ps1           <- GUI entry point; launches automatically at boot
            ├── Write-DeployLog.ps1    <- Logging (dot-sourced into every script)
            ├── Map-NetworkShare.ps1   <- Share auth + enumeration
            ├── Get-HardwareModel.ps1  <- WMI hardware detection (multi-vendor)
            └── Get-DriverPack.ps1     <- Driver pack scoring and selection

    [User confirms deployment]

    └── Invoke-Deployment.ps1         <- Orchestrator (runs in background runspace)
            ├── Apply-Image.ps1       <- diskpart + DISM apply + BCDboot
            ├── Expand-DriverPack.ps1  <- ZIP extraction to OS disk
            ├── Inject-Drivers.ps1     <- Offline DISM driver injection
            └── [generates]
                ├── unattend.xml       <- Written to W:\Windows\Panther\
                └── SetupComplete.cmd  <- Written to W:\Windows\Setup\Scripts\
```

All scripts are dot-sourced (`. "$ScriptRoot\..."`) so they share scope within the deployment runspace. The GUI runs on the main STA thread; the deployment pipeline runs in a separate runspace to keep the GUI responsive during long DISM operations.

---

## 2. WinPE Optional Components

Injected into the WIM during build by `Build-WinPE.ps1`.

| Component | Required | Purpose |
|---|---|---|
| WinPE-WMI | Yes | `Get-CimInstance Win32_ComputerSystem` for model detection |
| WinPE-NetFX | Yes | .NET Framework required for WinForms GUI |
| WinPE-Scripting | Yes | PowerShell script host infrastructure |
| WinPE-PowerShell | Yes | All scripts are PowerShell 5.1 |
| WinPE-StorageWMI | Yes | WMI disk queries |
| WinPE-DismCmdlets | Yes | PowerShell `Expand-WindowsImage` cmdlets (fallback) |
| WinPE-EnhancedStorage | Yes | eDrive / BitLocker-capable disk support |
| WinPE-Dot3Svc | Yes | 802.1X wired authentication on enterprise networks |
| WinPE-RNDIS | Recommended | USB-to-Ethernet NIC support for PXE fallback |
| WinPE-HTA | Yes | Required for WinForms control rendering in WinPE |
| WinPE-FontSupport-WinRE | Recommended | Full Segoe UI font set for GUI readability |
| WinPE-SecureStartup | Recommended | TPM / BitLocker handling on modern hardware |

---

## 3. Script Reference

### `startnet.cmd`
**Location in WIM:** `\Windows\System32\startnet.cmd`
**Called by:** Windows PE boot process, automatically

Runs `wpeinit` first (required — initializes network, PnP, and scratch space), waits 3 seconds for NIC initialization, then launches the deploy GUI via PowerShell. If the GUI exits with a non-zero error code, it drops to a `cmd.exe` diagnostic shell.

---

### `Write-DeployLog.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Logging\`
**Dot-sourced by:** all other scripts

Provides structured logging to `X:\Deploy\Logs\deploy.log` with timestamps and color-coded console output.

**Exported functions:**

| Function | Parameters | Description |
|---|---|---|
| `Initialize-Log` | `[string]$Path` | Creates log directory and writes session header |
| `Write-DeployLog` | `$Level`, `$Message`, `$Component` | Core logging function |
| `Write-LogInfo` | `$Msg`, `$Comp` | INFO level |
| `Write-LogWarn` | `$Msg`, `$Comp` | WARN level |
| `Write-LogError` | `$Msg`, `$Comp` | ERROR level |
| `Write-LogDebug` | `$Msg`, `$Comp` | DEBUG level |
| `Get-LogContent` | — | Returns full log as string |

---

### `Map-NetworkShare.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

Authenticates to the deployment share by passing credentials directly to `net use` (`cmdkey` is not available in WinPE). Credentials are scoped to the WinPE session only.

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Connect-NetworkShare` | `$SharePath`, `$Username`, `$Password` (SecureString), `$DriveLetter` | PSCustomObject: `Success`, `DriveLetter`, `ImagesPath`, `DriversPath`, `ErrorMessage` |
| `Disconnect-NetworkShare` | `$DriveLetter` | void |
| `Test-ShareConnectivity` | `$DriveLetter` | bool |
| `Get-AvailableImages` | `$ImagesPath` | Array: `Name`, `FullName`, `SizeGB`, `LastWriteTime` |
| `Get-AvailableDriverPacks` | `$DriversPath` | Array: `Name`, `FullName`, `IsZip`, `SizeMB`, `DisplayName` |

---

### `Get-HardwareModel.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Hardware\`

Queries `Win32_ComputerSystem` and `Win32_BIOS` via CIM to retrieve hardware identity. Works with Dell, Lenovo, HP, and generic hardware.

**Exported functions:**

| Function | Returns |
|---|---|
| `Get-HardwareInfo` | PSCustomObject: `Manufacturer`, `Model`, `ServiceTag`, `BIOSVersion`, `Vendor`, `ModelKey` |

`ModelKey` is `Model.ToLower().Replace(' ', '-')` — e.g. `"Latitude 5550"` -> `"latitude-5550"`. Used by the driver scorer and `DriverMap.json`.

---

### `Get-DriverPack.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Hardware\`

The driver auto-matching engine. Scores every ZIP on the share against the detected model and returns the best match. Vendor-agnostic — works with Dell, Lenovo, HP, and custom naming.

**Selection priority:**
1. JSON exact match (`DriverMap.json` `ZipFile` field)
2. ZIP filename scoring:
   - Model score (4-digit model number match — highest weight)
   - OS preference (`win11` > `win10`)
   - Revision (`_a19` > `_a06`, higher wins)

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Get-DriverPackInfo` | `$FileItem` | PSCustomObject: `OSHint`, `ModelHint`, `CleanHint`, `Platform`, `Version`, `SizeMB`, `DisplayName` |
| `Get-PackMatchScore` | `$Info`, `$ModelKey`, `$ModelRaw` | int (0-5+) |

---

### `Expand-DriverPack.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

Extracts a ZIP driver pack to `W:\DriverTemp\{basename}\` on the OS disk before DISM injection. Uses `System.IO.Compression.ZipFile` (.NET) with `Expand-Archive` as fallback. Reuses cached extractions within the same WinPE session.

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Expand-DriverPack` | `$ZipPath`, `$ExtractRoot`, `$Force`, `$StatusCallback` | PSCustomObject: `Success`, `ExtractPath`, `SizeMB`, `InfCount`, `WasCached`, `ErrorMessage` |
| `Clear-DriverTemp` | `$ExtractRoot` | void |

---

### `Apply-Image.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

Handles disk preparation, OS image application, and boot configuration.

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Invoke-DiskPrep` | `$DiskNumber`, `$OSDrive` | PSCustomObject: `Success`, `OSDriveLetter`, `EFIPartition` |
| `Apply-OSImage` | `$ImagePath`, `$TargetDrive`, `$ImageIndex`, `$StatusCallback` | bool |
| `Set-BootConfig` | `$OSDrive`, `$EFIDrive` | bool |
| `Get-WimImageInfo` | `$WimPath` | Array: `Index`, `Name`, `Description`, `SizeBytes`, `SizeGB`, `IsDeployable`, `IsDellIA`, `DisplayLabel` |
| `Get-DeployableImageIndex` | `$WimPath` | int (1 for stock WIMs) |

**Disk layout created by `Invoke-DiskPrep`:**

| Partition | Size | Format | Label | Drive |
|---|---|---|---|---|
| EFI System | 100 MB | FAT32 | System | S: |
| Microsoft Reserved | 16 MB | — | — | — |
| OS | Remaining disk | NTFS | Windows | W: (configurable) |

Windows Recovery (WinRE) is created automatically by Windows Setup during first boot — no need to pre-create it.

---

### `Inject-Drivers.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

Runs `dism /Add-Driver /Recurse` against the extracted driver pack folder, targeting the offline OS partition. DISM exit code 50 ("no drivers found") is treated as non-fatal.

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Invoke-DriverInjection` | `$DriverPackPath`, `$TargetDrive`, `$ForceUnsigned`, `$StatusCallback` | PSCustomObject: `Success`, `DriversAdded`, `DriversFailed`, `ErrorMessage` |
| `Get-InjectedDrivers` | `$TargetDrive` | Array: `Published`, `OrigName`, `Provider`, `Class` |

---

### `Invoke-Deployment.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

The orchestrator. Called by the GUI after user confirmation. Chains all deployment steps with progress reporting back to the GUI. Generates `unattend.xml` and `SetupComplete.cmd` dynamically from config.

**Pipeline steps and progress mapping:**

| Progress % | Step |
|---|---|
| 2 | Validate parameters |
| 5 | Detect hardware (WMI) |
| 10 | Partition disk (diskpart) |
| 15-75 | Apply OS image (DISM) |
| 76-79 | Extract driver ZIP |
| 80-88 | Inject drivers (DISM) |
| 88-90 | Generate unattend.xml + SetupComplete.cmd |
| 90 | Configure boot (BCDboot) |
| 95 | Write Deploy_Info.json |
| 100 | Complete |

**Generated files on deployed OS:**

| File | Purpose |
|---|---|
| `W:\Windows\Panther\unattend.xml` | Zero-touch Windows setup: computer name, domain join, product key, timezone, locale, OOBE bypass |
| `W:\Windows\Setup\Scripts\SetupComplete.cmd` | Post-setup automation: WiFi import, app installs from network share |
| `W:\DynamicPxE\WiFi\{SSID}.xml` | WiFi profile XML (if configured) |
| `W:\Deploy_Info.json` | Deployment metadata: date, model, service tag, image, driver pack |

**unattend.xml passes:**

| Pass | Components |
|---|---|
| specialize | Shell-Setup (computer name, org, timezone, product key), International-Core (locale), UnattendedJoin (domain join with credentials + OU), Deployment (BypassNRO via RunSynchronous) |
| oobeSystem | Shell-Setup (OOBE bypass: EULA, online accounts, wireless, OEM registration; local admin account with auto-logon; timezone; registered org/owner), International-Core (locale) |

**SetupComplete.cmd sections:**

1. WiFi profile import via `netsh wlan add profile` (import only, no forced connect — preserves ethernet)
2. Map app share (public, no credentials)
3. Install each app from config (MSI via `msiexec`, EXE via `start /wait`)
4. Per-app success/failure logging to `C:\DynamicPxE\Logs\SetupComplete.log`
5. Cleanup (unmap app share)

---

### `Start-DeployGUI.ps1`
**Location in WIM:** `X:\Deploy\Scripts\GUI\`

A WinForms application in PowerShell. Runs on the main STA thread. The deployment pipeline runs in a separate `Runspace` so DISM operations don't freeze the UI.

**4-page wizard flow:**

| Page | Cards | Purpose |
|---|---|---|
| Connect | This Machine, Network Share | Hardware info display, share credentials, Connect button |
| Select | OS Image (.wim), Driver Pack (.zip) | ListBoxes with refresh buttons, auto-match for drivers |
| Configure | Deployment Options, OS Configuration, WiFi, Post-Setup Apps, Deployment Summary | All settings editable, apps display (read-only from config) |
| Deploy | Deployment Progress, Deployment Log | Progress bar, status label, scrollable log viewer |

**Key architectural patterns:**
- `.GetNewClosure()` scriptblocks capture control references for cross-thread UI updates
- Background runspace receives pre-built closures (`$progressCallback`, `$onComplete`) — not function names
- `$script:BuildRoundedPath`, `$script:GetBrush`, `$script:GetPen` are captured scriptblock variables for GDI+ paint handlers (functions can't be resolved inside closures in WinPE)
- Sidebar navigation is locked (`$pm.Locked = $true`) during active deployment
- Machine reboots immediately after successful deployment (no countdown timer — WinForms Timer has scope limitations in WinPE closures)

---

## 4. GUI Framework

### `Initialize-GUIFramework.ps1`
Master loader — dot-sources all framework files in correct order.

### `ThemeEngine.ps1`
15-color dark palette with DPI-aware scaling. All colors configurable via `Theme.Colors` in config.

### `LayoutHelpers.ps1`
`New-AppShell` creates the main form with sidebar, content area, action bar, and status bar. `New-CardPanel` creates bordered card containers with optional titles.

### `PageManager.ps1`
Wizard state machine. Tracks active page, completed pages, sidebar step indicators. `Locked` flag prevents navigation during deployment.

### `CustomControls.ps1`
Owner-drawn controls using GDI+ `GraphicsPath` for rounded corners. All paint handlers use captured scriptblock variables (`$buildPath`, `$getBrush`, `$getPen`) wrapped in try/catch.

### `AnimationEngine.ps1`
Timer-based color transitions for hover effects. Cubic ease-out for toast slide animations.

---

## 5. Drive Letter Assignments

| Drive | Contents | Assigned by |
|---|---|---|
| X: | WinPE RAM disk | WinPE automatically |
| Z: | Deploy share (`\\server\deploy-share`) | `Map-NetworkShare.ps1` |
| S: | EFI System Partition | diskpart |
| W: | OS partition (target Windows) | diskpart |
| Y: | App share (post-setup, in SetupComplete.cmd) | `net use` in SetupComplete.cmd |

WinPE-session assignments only. After reboot, Windows assigns its own letters (typically `C:` for OS).

---

## 6. Configuration Reference

### DeployConfig.json — Full Schema

```
Network
  ShareRoot           UNC path to deployment share
  DriveLetter         Drive letter in WinPE (default: Z:)
  ImagesSubfolder     Subfolder for WIM files (default: Images)
  DriversSubfolder    Subfolder for driver ZIPs (default: Drivers)

App
  AppTitle            Window title
  AppVersion          Status bar version
  OrgName             Organization name (used in unattend.xml)
  BuildLabel          Title bar build info
  DefaultDomainPrefix Pre-fills username field (e.g. DOMAIN\)

Deployment
  DefaultImageIndex   WIM index (1 for stock Microsoft WIMs)
  DefaultTargetDisk   Physical disk number (0 = first disk)
  ComputerNameTemplate  Name with %SERVICETAG%, %MODEL%, %VENDOR% (max 15 chars)
  DomainName          AD domain FQDN (empty = skip join)
  DomainOU            Target OU distinguished name
  ProductKey          MAK or retail key (empty = skip)
  Timezone            Windows timezone name (tzutil /l for list)
  InputLocale         Keyboard layout (e.g. 0409:00000409)
  SystemLocale        System locale (e.g. en-US)
  UserLocale          User locale (e.g. en-US)
  WifiSSID            WiFi network name (empty = skip)
  WifiPassword        WiFi password (WPA2-PSK)

Apps
  SharePath           UNC path to app share (public, no credentials)
  DriveLetter         Drive letter for app share (default: Y:)
  Packages[]          Array of app objects:
    Name              Display name (for logging)
    Path              Relative path from SharePath to installer
    Args              Silent install arguments

Theme
  Colors.Accent       Hex color override
  Fonts.Family        Font family name
  Fonts.BodySize      Body font size
  AnimationsEnabled   Enable/disable hover animations
  CornerRadius        Rounded corner radius in pixels

Layout
  SidebarWidth        Wizard sidebar width in pixels

Branding
  LogoPath            PNG logo file path in WinPE
  IconPath            ICO file path in WinPE
```

---

## 7. Security Notes

- Share credentials are passed directly to `net use` and scoped to the WinPE session only. They do not persist to the installed OS.
- Domain join reuses the share credentials — no separate domain credentials are stored. The domain prefix is automatically stripped from the username for DJOIN compatibility.
- App share is public (no credentials). The `net use` in SetupComplete.cmd maps without authentication.
- WiFi password is written to `C:\DynamicPxE\WiFi\{SSID}.xml` in plaintext. Clear after deployment if needed.
- PowerShell execution policy is set to `Unrestricted` in the WinPE image only.
- The GUI requires explicit confirmation (YesNo MessageBox) before any disk operation.
- DISM logs are written to `X:\Windows\Logs\DISM\dism.log` on the WinPE RAM disk.

---

## 8. Troubleshooting

### GUI does not launch — drops to command prompt

Check WinPE optional components:
```cmd
dism /Get-Packages /Image:X:\
powershell.exe -ExecutionPolicy Bypass -File X:\Deploy\Scripts\GUI\Start-DeployGUI.ps1
type X:\Deploy\Logs\deploy.log
```

### Network share will not connect

```cmd
ping your-server
net use \\your-server\deploy-share /user:DOMAIN\username
```

Common causes: wpeinit hasn't finished (increase delay in startnet.cmd), firewall blocking SMB, wrong credential format.

### DISM image apply fails

```cmd
wmic logicaldisk get caption,size,freespace
dism /Check-ImageHealth /ImageFile:Z:\Images\Win11.wim
type X:\Windows\Logs\DISM\dism.log
```

### Specialize pass fails (unattend.xml error)

Check that the disk layout matches Microsoft's expected GPT structure. The current layout uses: EFI (100MB) + MSR (16MB) + OS (remaining). No recovery partition is pre-created — Windows creates WinRE automatically.

Verify the unattend.xml is well-formed:
```cmd
type W:\Windows\Panther\unattend.xml
```

### Domain join fails after reboot

Check `C:\Windows\debug\NetSetup.LOG` on the deployed OS. Common causes: wrong domain name, insufficient permissions on the domain account, OU path typo.

### Apps not installing

Check `C:\DynamicPxE\Logs\SetupComplete.log`. Verify the app share is accessible without credentials and installer paths match config.

### Driver not auto-selected

Scoring requires match score >= 3. Check the deployment log. Add a `DriverMap.json` override if auto-matching fails.
