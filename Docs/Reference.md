# Dell Image Assist — Technical Reference

This document covers the internals of every component: what each script does, what it expects, what it returns, and how the pieces connect. For step-by-step build and deployment instructions, see `Deployment.md`.

---

## 1. System Architecture

```
startnet.cmd
    └── Start-DeployGUI.ps1           ← GUI entry point; runs on WinPE boot
            ├── Write-DeployLog.ps1   ← Logging (dot-sourced into every script)
            ├── Map-NetworkShare.ps1  ← Share auth + enumeration
            ├── Get-DellModel.ps1     ← WMI hardware detection
            └── Get-DellDriverPack.ps1 ← Driver pack scoring and selection

    [User confirms deployment]

    └── Invoke-Deployment.ps1         ← Orchestrator (runs in background runspace)
            ├── Apply-Image.ps1       ← diskpart + DISM apply + BCDboot
            ├── Expand-DriverPack.ps1 ← ZIP extraction to RAM disk
            └── Inject-Drivers.ps1    ← Offline DISM driver injection
```

All scripts are dot-sourced (`. "$ScriptRoot\..."`) so they share scope within the deployment runspace. The GUI runs on the main STA thread; the deployment pipeline runs in a separate runspace to keep the GUI responsive during long DISM operations.

---

## 2. WinPE Optional Components

These are injected into the WIM during build by `Build-WinPE.cmd`.

| Component | Required | Purpose |
|---|---|---|
| WinPE-WMI | ✅ | `Get-CimInstance Win32_ComputerSystem` for model detection |
| WinPE-NetFX | ✅ | .NET Framework required for WinForms GUI |
| WinPE-Scripting | ✅ | PowerShell script host infrastructure |
| WinPE-PowerShell | ✅ | All scripts are PowerShell 5.1 |
| WinPE-StorageWMI | ✅ | WMI disk queries |
| WinPE-DismCmdlets | ✅ | PowerShell `Expand-WindowsImage` cmdlets (used as fallback) |
| WinPE-EnhancedStorage | ✅ | eDrive / BitLocker-capable disk support |
| WinPE-Dot3Svc | ✅ | 802.1X wired authentication on enterprise networks |
| WinPE-RNDIS | Recommended | USB-to-Ethernet NIC support for PXE fallback |
| WinPE-HTA | ✅ | Required for WinForms control rendering in WinPE |
| WinPE-FontSupport-WinRE | Recommended | Full Segoe UI font set for GUI readability |
| WinPE-SecureStartup | Recommended | TPM / BitLocker handling on modern Dell hardware |

---

## 3. Script Reference

### `startnet.cmd`
**Location in WIM:** `\Windows\System32\startnet.cmd`  
**Called by:** Windows PE boot process, automatically

Runs `wpeinit` first (required — initializes network, PnP, and scratch space), waits 3 seconds for NIC initialization, then launches the GUI via PowerShell. If the GUI exits with a non-zero error code, it drops to a `cmd.exe` diagnostic shell. A second GUI launch is attempted after the shell exits.

---

### `Write-DeployLog.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Logging\`  
**Dot-sourced by:** all other scripts

Provides structured logging to `X:\Deploy\Logs\deploy.log` with timestamps and color-coded console output. Must be initialized with `Initialize-Log` before first use.

**Exported functions:**

| Function | Parameters | Description |
|---|---|---|
| `Initialize-Log` | `[string]$Path` | Creates log directory and writes session header |
| `Write-DeployLog` | `$Level`, `$Message`, `$Component` | Core logging function |
| `Write-LogInfo` | `$Msg`, `$Comp` | Convenience wrapper — INFO level |
| `Write-LogWarn` | `$Msg`, `$Comp` | Convenience wrapper — WARN level |
| `Write-LogError` | `$Msg`, `$Comp` | Convenience wrapper — ERROR level |
| `Write-LogDebug` | `$Msg`, `$Comp` | Convenience wrapper — DEBUG level |
| `Get-LogContent` | — | Returns full log as string (used by GUI log panel) |

Log levels are color-coded in the console: DEBUG=Gray, INFO=Cyan, WARN=Yellow, ERROR=Red.

---

### `Map-NetworkShare.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

Authenticates to the deployment share using `cmdkey` for credential caching, then maps it with `net use`. Credentials are stored in Windows Credential Manager for the WinPE session only — they do not persist to the installed OS.

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Connect-NetworkShare` | `$SharePath`, `$Username`, `$Password` (SecureString), `$DriveLetter` | PSCustomObject: `Success`, `DriveLetter`, `ImagesPath`, `DriversPath`, `ErrorMessage` |
| `Disconnect-NetworkShare` | `$DriveLetter` | void |
| `Test-ShareConnectivity` | `$DriveLetter` | bool |
| `Get-AvailableImages` | `$ImagesPath` | Array of objects: `Name`, `FullName`, `SizeGB`, `LastWriteTime` |
| `Get-AvailableDriverPacks` | `$DriversPath` | Array of objects: `Name`, `FullName`, `IsZip`, `SizeMB`, `DisplayName` |

Share root: `\\your-server\your-share`
Default drive letter: `Z:`  
Images path: `Z:\Images`  
Drivers path: `Z:\Drivers`

---

### `Get-DellModel.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Dell\`

Queries `Win32_ComputerSystem` and `Win32_BIOS` via CIM to retrieve hardware identity. Returns a normalized model key suitable for driver pack matching.

**Exported functions:**

| Function | Returns |
|---|---|
| `Get-DellModel` | PSCustomObject: `Manufacturer`, `Model`, `SystemFamily`, `ServiceTag`, `BIOSVersion`, `IsDell`, `ModelKey` |
| `Get-DellModelString` | Formatted string for display |

`ModelKey` is `Model.ToLower().Replace(' ', '-')` — e.g. `"Latitude 5550"` → `"latitude-5550"`. This is what the driver scorer and `DellDriverMap.json` use.

---

### `Get-DellDriverPack.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Dell\`

The driver auto-matching engine. Scores every ZIP on the share against the detected model and returns the best match.

**Selection priority (in order):**
1. JSON exact match (`DellDriverMap.json` `ZipFile` field, if populated)
2. JSON fuzzy match
3. ZIP filename scoring (primary path for all standard cases):
   - Model score (4-digit model number match — highest weight)
   - OS preference (`win11` = 1, `win10` = 0)
   - Revision (`_a19` = 19, higher wins)
4. Pre-extracted folder fallback (edge case only)

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Get-DellDriverPack` | `$ModelKey`, `$ModelRaw`, `$DriversRoot`, `$MapFile` | PSCustomObject: `IsMatched`, `MatchType`, `IsZip`, `PackName`, `DriverPackPath`, `AllPacks` |
| `Get-DriverPackInfo` | `$FileItem` | PSCustomObject: `OSHint`, `ModelHint`, `CleanHint`, `Platform`, `Version`, `SizeMB`, `DisplayName` |
| `Get-ZipMatchScore` | `$Info`, `$ModelKey`, `$ModelRaw` | int (0–5+) |
| `Get-PackRevision` | `$FileName` | int (e.g. 19 from `_a19`) |
| `Get-AllDriverPacks` | `$DriversRoot` | Array of DriverPackInfo objects |

**Dell ZIP naming convention decoded:**

| Token in filename | Meaning |
|---|---|
| `win11` / `win10` | Target OS |
| `latitude`, `optiplex`, `precision`, `vostro` | Product family |
| `e13`, `e14`, `e15`, `e16` | Screen size hint (13", 14", etc.) |
| `tgl`, `mlk`, `whl`, `rpl`, `mtl`, `adl` | Platform codename (Tiger Lake, Meteor Lake, etc.) |
| `d9`, `d11`, `d12`, `d13` | OptiPlex generation shorthand |
| `a06`, `a17`, `a19` | Revision — higher is newer |

---

### `Expand-DriverPack.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

Extracts a ZIP driver pack to `X:\Deploy\DriverTemp\{basename}\` on the WinPE RAM disk before DISM injection. Uses `System.IO.Compression.ZipFile` (.NET) as primary method with `Expand-Archive` as fallback. If the same ZIP was already extracted in the current WinPE session, it reuses the existing extraction without re-extracting.

After DISM injection completes, `Clear-DriverTemp` is called automatically to free RAM disk space (driver ZIPs uncompressed can be 4–8 GB; the WinPE scratch space is set to 512 MB, but the RAM disk itself has more headroom).

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Expand-DriverPack` | `$ZipPath`, `$ExtractRoot`, `$Force`, `$StatusCallback` | PSCustomObject: `Success`, `ExtractPath`, `SizeMB`, `InfCount`, `WasCached`, `ErrorMessage` |
| `Clear-DriverTemp` | `$ExtractRoot` | void |
| `Get-DriverPackInfo` | `$FileItem` | Same as in `Get-DellDriverPack.ps1` |

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
| `Get-WimImageInfo` | `$WimPath` | Array of PSCustomObjects: `Index`, `Name`, `Description`, `SizeBytes`, `SizeGB`, `IsDeployable`, `IsDellIA`, `DisplayLabel` |
| `Get-DeployableImageIndex` | `$WimPath` | int — returns 2 for Dell IA WIMs, 1 for standard WIMs |

**Dell Image Assist WIM index structure:**

Dell Image Assist captures produce a 5-index WIM where only index 2 is the deployable Windows OS. The system auto-detects this structure and sets the index field accordingly.

| Index | Name | Description | Deployable | Purpose |
|---|---|---|---|---|
| 1 | BLANK1 | System | ❌ | Dell IA system partition data |
| 2 | BLANK2 | Windows_IW | ✅ **Always deploy this** | The actual Windows installation |
| 3 | BLANK3 | Recovery | ❌ | Recovery placeholder (0 bytes) |
| 4 | BLANK4 | Summary_IA | ❌ | Dell IA deployment metadata |
| 5 | BLANK5 | Logs | ❌ | Dell IA capture logs |

Detection logic: if a WIM has exactly 5 indexes and index 2 description is `Windows_IW`, it is identified as a Dell IA WIM. The GUI auto-sets the index field to 2 and turns the info label green. A warning dialog fires if the technician manually changes the index to 1.

**Disk layout created by `Invoke-DiskPrep`:**

| Partition | Size | Format | Label | Drive |
|---|---|---|---|---|
| EFI System | 260 MB | FAT32 | System | S: |
| Microsoft Reserved | 16 MB | — | — | — |
| OS | Remaining − 650 MB | NTFS | Windows | W: |
| Recovery | 650 MB | NTFS | Recovery | — |

The Recovery partition has its GPT attributes set (`0x8000000000000001`) and partition type GUID (`de94bba4-...`) to hide it from Windows Explorer and mark it as WinRE-capable.

---

### `Inject-Drivers.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

Runs `dism /Add-Driver /Recurse` against the extracted driver pack folder, targeting the offline OS partition at `W:\`. DISM exit code 50 ("no drivers found") is treated as non-fatal since some category folders (e.g. `application\`) don't contain injectable INF files.

**Exported functions:**

| Function | Key Parameters | Returns |
|---|---|---|
| `Invoke-DriverInjection` | `$DriverPackPath`, `$TargetDrive`, `$ForceUnsigned`, `$StatusCallback` | PSCustomObject: `Success`, `DriversAdded`, `DriversFailed`, `ErrorMessage` |
| `Get-InjectedDrivers` | `$TargetDrive` | Array: `Published`, `OrigName`, `Provider`, `Class` |

---

### `Invoke-Deployment.ps1`
**Location in WIM:** `X:\Deploy\Scripts\Core\`

The orchestrator. Called by the GUI after user confirmation. Chains all deployment steps in order with progress reporting back to the GUI via `$ProgressCallback`. A `$ConfirmWipe = $true` safety gate must be explicitly set to prevent accidental disk destruction.

**Pipeline steps and progress mapping:**

| Progress % | Step |
|---|---|
| 2 | Validate parameters |
| 5 | Detect hardware (WMI) |
| 10 | Partition disk (diskpart) |
| 15–75 | Apply OS image (DISM) |
| 76–79 | Extract driver ZIP |
| 80–88 | Inject drivers (DISM) |
| 90 | Configure boot (BCDboot) |
| 95 | Write Deploy_Info.json |
| 100 | Complete |

On completion, `Deploy_Info.json` is written to `W:\` containing: `DeployDate`, `Model`, `ServiceTag`, `ImageApplied`, `DriverPack`, `ImageIndex`.

---

### `Start-DeployGUI.ps1`
**Location in WIM:** `X:\Deploy\Scripts\GUI\`

A single-file PowerShell WinForms application (~650 lines). Runs on the main STA thread. The deployment pipeline runs in a separate `Runspace` so DISM operations don't freeze the UI.

**GUI panels:**

| Panel | Function |
|---|---|
| Hardware Detection | Displays detected model and service tag on load |
| Network Authentication | Username/password fields, Connect button |
| OS Image Selection | ListBox populated from `Z:\Images\` after connect |
| Driver Pack Selection | ListBox with auto-matched item highlighted |
| Deployment Summary | Shows selected image, driver pack, image index, target disk |
| Progress | Progress bar + status text updated by deployment callbacks |
| Log | Live scrolling log panel (RichTextBox, Consolas monospace) |

**Keyboard shortcuts:**
- `F5` — Refresh image and driver pack lists
- `Escape` — Confirm-exit to WinPE command prompt

---

## 4. Drive Letter Assignments During Deployment

| Drive | Contents | Assigned by |
|---|---|---|
| X: | WinPE RAM disk | WinPE automatically |
| Z: | Network share (`\\your-server\your-share`) | `Map-NetworkShare.ps1` |
| S: | EFI System Partition | diskpart |
| W: | OS partition (target Windows installation) | diskpart |

These are WinPE-session assignments only. After reboot, Windows assigns its own drive letters (typically `C:` for OS).

---

## 5. Dell Driver Pack ZIP Naming — Extended Reference

Dell publishes driver packs at: https://www.dell.com/support/kbdoc/en-us/000108728

**Full naming breakdown for your current inventory:**

| Filename | Family | Platform | Model | Revision |
|---|---|---|---|---|
| `win10_latitudee10_a23.zip` | Latitude | — | E10 | a23 |
| `win10_latitudee11whl2_a15.zip` | Latitude | WHL2 | E11 | a15 |
| `win10_latitudee13tgl5320_a06.zip` | Latitude | TGL | 5320 (13") | a06 |
| `win10_latitudee13tgl5520_a06.zip` | Latitude | TGL | 5520 (13") | a06 |
| `win10_latitudee14mlk5530_a03.zip` | Latitude | MLK | 5530 (14") | a03 |
| `win10_optiplexd11_a12.zip` | OptiPlex | — | Gen11 family | a12 |
| `win10_optiplexd12_a03.zip` | OptiPlex | — | Gen12 family | a03 |
| `win10_optiplexd9mlk_a15.zip` | OptiPlex | MLK | Gen9 | a15 |
| `win10_optiplexd9_a23.zip` | OptiPlex | — | Gen9 | a23 |
| `win10_precisionm10mlk3550_a12.zip` | Precision | MLK | 3550 mobile | a12 |
| `win10_precisionm8whl_a14.zip` | Precision | WHL | Gen8 mobile | a14 |
| `win10_precisionws10_a11.zip` | Precision | — | Gen10 workstation | a11 |
| `win11_dellprolaptopse17pc16250rpl_a05.zip` | Dell Pro | RPL | 16" laptop | a05 |
| `win11_latitude5550_a06.zip` | Latitude | — | 5550 | a06 |
| `win11_latitudee13tgl5320_a17.zip` | Latitude | TGL | 5320 (13") | a17 |
| `win11_latitudee13tgl5520_a18.zip` | Latitude | TGL | 5520 (13") | a18 |
| `win11_latitudee14mlk5530_a16.zip` | Latitude | MLK | 5530 (14") | a16 |
| `win11_latitudee16mtl5550_a12.zip` | Latitude | MTL | 5550 (16") | a12 |
| `Win11_latitudee5550_a19.zip` | Latitude | — | 5550 | a19 ← newest for 5550 |
| `win11_optiplexd11_a21.zip` | OptiPlex | — | Gen11 family | a21 |
| `win11_optiplexd12_a14.zip` | OptiPlex | — | Gen12 family | a14 |
| `win11_optiplexd13mlk7020_a09.zip` | OptiPlex | MLK | 7020 Gen13 | a09 |
| `win11_optiplexd13mlk7020_a17.zip` | OptiPlex | MLK | 7020 Gen13 | a17 ← newest |
| `win11_precisionm11tgl3560_a19.zip` | Precision | TGL | 3560 mobile | a19 |

**OptiPlex "d" generation codes:**  
`d9` = 9th gen · `d11` = 11th gen · `d12` = 12th gen · `d13` = 13th gen  
A single d-series pack covers all OptiPlex models in that generation (3000/5000/7000 series).

---

## 6. Security Notes

- Share credentials are stored in Windows Credential Manager via `cmdkey`. The plaintext password variable is zeroed immediately after `cmdkey` stores it.
- Credential Manager entries are scoped to the WinPE session. They do not survive reboot and are not accessible to the deployed OS.
- PowerShell execution policy is set to `Unrestricted` via a registry hive edit at build time, scoped to the WinPE image only.
- The GUI requires explicit typed confirmation (`YesNo` MessageBox) before any disk operation. The `ConfirmWipe = $true` parameter in `Invoke-Deployment.ps1` cannot be set by the GUI without user interaction.
- The deployment share service account should have read-only access to both `Images\` and `Drivers\`. No write permissions are needed.
- DISM logs are written to `X:\Windows\Logs\DISM\dism.log` on the WinPE RAM disk.

---

## 7. Troubleshooting

### GUI does not launch — drops to command prompt

The most common cause is missing WinPE optional components in the WIM. Check:

```cmd
:: From WinPE command prompt:
dism /Get-Packages /Image:X:\   :: should list WinPE-NetFX, WinPE-PowerShell, WinPE-HTA
powershell.exe -ExecutionPolicy Bypass -File X:\Deploy\Scripts\GUI\Start-DeployGUI.ps1
:: Check the error output
type X:\Deploy\Logs\deploy.log
```

### Network share will not connect

```cmd
:: Test basic connectivity
ping your-server

:: Test SMB manually
net use \\your-server\your-share /user:DOMAIN\username

:: Check wpeinit ran
:: If startnet.cmd ran correctly, wpeinit ran first - if NIC isn't up, wait longer
```

Common causes: wpeinit hasn't finished initializing the NIC (increase the ping delay in startnet.cmd from 3 to 6 seconds), firewall blocking SMB on the server, or wrong credential format (try `DOMAIN\user`, then `.\user`, then just `user`).

### DISM image apply fails

```cmd
:: Check scratch space
wmic logicaldisk get caption,size,freespace

:: Verify WIM integrity
dism /Check-ImageHealth /ImageFile:Z:\Images\yourimage.wim

:: Check DISM log
type X:\Windows\Logs\DISM\dism.log | more
```

If DISM reports "not enough space," the WinPE scratch space setting (512 MB in the WIM) may need to increase. Edit `Build-WinPE.cmd` and change the `Set-ScratchSpace` value.

### Drivers not loading after reboot

First check that injection succeeded:
```cmd
:: Before rebooting, from WinPE:
dism /Image:W:\ /Get-Drivers /Format:Table
```

If drivers were injected but don't load in Windows, the most common cause is a driver requiring an OS version newer than what was deployed. The `win11_` packs are for Windows 11 — if a Windows 10 image was applied, some drivers will silently fail to load.

### Deploy_Info.json missing after reboot

This means deployment completed the image apply and driver inject but BCDboot or the final write step failed. Check `X:\Deploy\Logs\deploy.log` before rebooting — the log persists until WinPE session ends.

### "No driver pack matched" in GUI

The auto-scorer couldn't confidently identify a pack for this model. Either:
1. No pack for this model exists on the share yet — download and add it
2. The model is new enough that the filename token doesn't parse cleanly — add a `ZipFile` entry to `DellDriverMap.json`
3. The WMI model string is unusual — run `(Get-CimInstance Win32_ComputerSystem).Model` on the machine and compare it to your ZIP filenames manually

---

## 8. Adding Lenovo Support

The extension points are intentionally minimal.

**Files to create:**

`Scripts/Lenovo/Get-LenovoModel.ps1` — Must export `Get-LenovoModel` returning a PSCustomObject with the same property names as `Get-DellModel`: `Manufacturer`, `Model`, `ModelKey`, `ServiceTag`, `IsDell` (set to `$false`), etc. Add an `IsLenovo` property.

`Scripts/Lenovo/Get-LenovoDriverPack.ps1` — Must export `Get-LenovoDriverPack` with the same parameter and return signature as `Get-DellDriverPack`. Lenovo SCCM packs use a different naming convention; the scorer will need adjustment for Lenovo's `tp_` prefixes.

`Config/LenovoDriverMap.json` — Same schema as `DellDriverMap.json`.

**File to edit:**

`Scripts/Core/Invoke-Deployment.ps1` — Find the two `# FUTURE: Lenovo` comment blocks and uncomment them. One is in the import section (dot-source the new scripts), one is the manufacturer branch in the hardware detection step.

**No changes needed to:** GUI, `Apply-Image.ps1`, `Inject-Drivers.ps1`, `Expand-DriverPack.ps1`, `Map-NetworkShare.ps1`, `Build-WinPE.cmd`, `startnet.cmd`.
