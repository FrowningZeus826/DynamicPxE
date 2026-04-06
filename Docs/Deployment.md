# DynamicPxE — Build & Deployment Guide

This document covers everything from initial setup through your first successful deployment. Follow the phases in order. Estimated time for a first-time build: 45-90 minutes. Subsequent builds after updating scripts: under 10 minutes.

---

## Phase 1: Prerequisites & Project Setup

### 1.1 — Software Required on the Build Machine

The build machine is a Windows 10 or Windows 11 x64 workstation. You need Administrator access.

**Windows ADK 26100 (Assessment and Deployment Kit)**

1. Go to: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
2. Download **"Download the Windows ADK"** for Windows 11, version 26100
3. Run the installer as Administrator
4. On the feature selection screen, check **Deployment Tools** only — uncheck everything else
5. Default install path: `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\`

**WinPE Add-on for ADK 26100**

1. On the same download page, download **"Download the Windows PE add-on for the Windows ADK"**
2. This is a separate installer — the ADK alone does not include WinPE
3. Run the installer as Administrator — accept all defaults
4. Must match your ADK version exactly (26100)
5. Install this **after** the ADK, not before

**Vendor WinPE Driver Pack**

You need WinPE-specific drivers so that WinPE can see the NVMe SSD and NIC on modern hardware. Download the WinPE driver pack for your primary hardware vendor:

- **Dell:** https://www.dell.com/support/kbdoc/en-us/000108728 — download the "WinPE 11" CAB
- **Lenovo:** Search for "Lenovo WinPE driver pack" on Lenovo support
- **HP:** Search for "HP WinPE driver pack" on HP support

> **WinPE drivers vs OS driver packs — what's the difference?**
>
> | | WinPE Driver Pack | OS Driver Packs (ZIPs on share) |
> |---|---|---|
> | Purpose | Lets WinPE see the disk and NIC at boot | Installs drivers into deployed Windows |
> | Where it goes | Extracted into `WinPEDrivers\` on build machine | Placed as-is on the network share |
> | When used | Baked into `boot.wim` at build time | Injected into the OS at deploy time |
> | How many | One universal pack per vendor | One ZIP per model family |

---

### 1.2 — Create the Project Folder

Open an **elevated command prompt** and run:

```cmd
mkdir C:\DynamicPxE
mkdir C:\DynamicPxE\Build
mkdir C:\DynamicPxE\Build\Mount
mkdir C:\DynamicPxE\WinPEDrivers
```

### 1.3 — Copy the Project Files

Copy all files from this repository into `C:\DynamicPxE\` maintaining the folder structure.

After copying, verify the key files are in place:

```cmd
dir C:\DynamicPxE\Build-WinPE.ps1
dir C:\DynamicPxE\startnet.cmd
dir C:\DynamicPxE\Scripts\GUI\Start-DeployGUI.ps1
dir C:\DynamicPxE\Scripts\Core\Invoke-Deployment.ps1
```

### 1.4 — Extract the WinPE Driver Pack

The driver CAB/ZIP must be extracted into `WinPEDrivers\` before building. DISM requires loose INF and SYS files.

```cmd
:: Dell CAB example:
expand.exe -F:* "C:\Users\YourName\Downloads\WinPE11.0-Drivers-A01.cab" C:\DynamicPxE\WinPEDrivers

:: Lenovo/HP ZIP example:
:: Extract the ZIP contents into C:\DynamicPxE\WinPEDrivers\
```

Verify the extraction:
```cmd
dir C:\DynamicPxE\WinPEDrivers
```

You should see subfolders like `network\`, `storage\`, etc. The two critical subfolders are `storage\` (NVMe) and `network\` (NIC). Without these, WinPE cannot see the disk or reach the network.

### 1.5 — Verify ADK Installation

```cmd
:: Must exist — proves WinPE Add-on is installed
dir "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\en-us\winpe.wim"

:: Must exist — proves ADK Deployment Tools are installed
dir "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\DandISetEnv.bat"
```

Both files must be present. If either is missing, re-run the corresponding installer.

---

## Phase 2: Prepare the Network Shares

### 2.1 — Deployment Share

Create a folder structure on your file server and share it:

```
\\your-server\deploy-share\
├── Images\       (stock install.wim files from Microsoft ISOs)
└── Drivers\      (vendor driver pack ZIPs)
```

**Share permissions:** The deployment service account needs `Read` access.
**NTFS permissions:** `Read & Execute` on all subfolders.

Use a dedicated service account (e.g. `DOMAIN\svc-deploy`) rather than a personal account. These credentials are entered at the GUI prompt each deployment and are also reused for domain join. The domain prefix is stripped automatically when passed to DJOIN.

### 2.2 — Add OS Images

Place stock `install.wim` files from Microsoft Windows ISOs in the `Images\` folder:

```
\\your-server\deploy-share\Images\
    Win11_24H2_Enterprise_x64.wim
    Win11_23H2_Pro_x64.wim
```

**How to get install.wim:**
1. Download a Windows 11 ISO from Microsoft (Volume Licensing Service Center or Media Creation Tool)
2. Mount the ISO
3. Copy `sources\install.wim` to your share's `Images\` folder
4. Rename it descriptively — the filename is what appears in the GUI

> **Note:** Media Creation Tool ISOs may contain `install.esd` instead of `install.wim`. You can convert it using: `dism /Export-Image /SourceImageFile:install.esd /SourceIndex:1 /DestinationImageFile:install.wim /Compress:max`

### 2.3 — Add Driver Packs

Place vendor driver ZIP files directly in the `Drivers\` folder:

```
\\your-server\deploy-share\Drivers\
    Win11_latitudee5550_a19.zip           (Dell)
    win11_optiplexd13mlk7020_a17.zip      (Dell)
    lenovo_thinkpade16g1_win11_a03.zip    (Lenovo)
    hp_elitebook840g10_win11.zip          (HP)
```

**Naming:** Keep the vendor's original filenames. The auto-matching engine parses filenames to extract OS, model token, and revision. Renaming ZIPs may break auto-matching.

**Adding new models:** Just drop the new ZIP on the share. The next deployment will include it in the scoring pool. If auto-matching picks the wrong pack, add an override in `DriverMap.json`.

### 2.4 — App Share (Optional)

If you want post-setup app installs, create a **separate public share** (no credentials needed):

```
\\your-server\apps-share\
├── Chrome\
│   └── GoogleChromeStandaloneEnterprise64.msi
├── AdobeReader\
│   └── AcroRdrDC_en_US.exe
└── 7-Zip\
    └── 7z2409-x64.msi
```

This share must be accessible without authentication from the deployed machine after it joins the domain and reboots.

---

## Phase 3: Configure

### 3.1 — Create Config Files

Config files are excluded from the repo. Copy the examples:

```powershell
Copy-Item Config\DeployConfig.example.json  Config\DeployConfig.json
Copy-Item Config\DriverMap.example.json     Config\DriverMap.json
```

### 3.2 — Edit DeployConfig.json

At minimum, set these sections:

**Network** — your deployment share:
```json
"Network": {
    "ShareRoot": "\\\\your-server\\deploy-share",
    "DriveLetter": "Z:",
    "ImagesSubfolder": "Images",
    "DriversSubfolder": "Drivers"
}
```

**Deployment** — OS configuration defaults:
```json
"Deployment": {
    "ComputerNameTemplate": "PC-%SERVICETAG%",
    "DomainName": "corp.example.com",
    "DomainOU": "OU=Workstations,DC=corp,DC=example,DC=com",
    "ProductKey": "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX",
    "Timezone": "Eastern Standard Time",
    "DefaultImageIndex": 1
}
```

**Apps** — post-setup app installs (optional):
```json
"Apps": {
    "SharePath": "\\\\your-server\\apps-share",
    "DriveLetter": "Y:",
    "Packages": [
        {
            "Name": "Google Chrome",
            "Path": "Chrome\\GoogleChromeStandaloneEnterprise64.msi",
            "Args": "/qn /norestart"
        }
    ]
}
```

All deployment settings can be overridden in the GUI at boot time. The config file provides defaults.

See `Config/DeployConfig.example.json` for the full list of settings with documentation.

---

## Phase 4: Build the WinPE Boot Image

### 4.1 — Run the Build

Open an elevated PowerShell prompt:

```powershell
cd C:\DynamicPxE
.\Build-WinPE.ps1
```

The script runs 9 numbered steps:

1. **Environment setup** — cleans stale mounts, creates build folders
2. **Copy WinPE media** — stages boot files from the ADK
3. **Mount boot.wim** — mounts the WinPE image for modification
4. **Install optional components** — WMI, NetFX, PowerShell, HTA, StorageWMI, networking, GUI
5. **Configure settings** — 512 MB scratch space, timezone, execution policy
6. **Inject scripts** — copies all deployment scripts, config, and `startnet.cmd` into the WIM
7. **Inject WinPE drivers** — injects all INF/SYS files from `WinPEDrivers\` recursively
8. **Verify** — confirms script count and `startnet.cmd` are present
9. **Unmount and save** — commits changes, copies final `boot.wim` to project root

**Expected runtime:** 10-25 minutes. Output: `C:\DynamicPxE\boot.wim`

### 4.2 — If the Build Fails

**"winpe.wim not found"** — WinPE Add-on not installed. Re-run the WinPE installer.

**"ADK dism.exe not found"** — ADK Deployment Tools not installed. Re-run the ADK installer.

**Script fails partway through** — stale WIM mount. Clean up and retry:
```powershell
.\Repair-Build.ps1
.\Build-WinPE.ps1
```

### 4.3 — Quick Update (Scripts Only)

If you update PowerShell scripts or config without changing WinPE components:

```powershell
$dism    = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\AMD64\DISM\dism.exe"
$wim     = "C:\DynamicPxE\boot.wim"
$mount   = "C:\DynamicPxE\Build\Mount"
$project = "C:\DynamicPxE"

New-Item -ItemType Directory -Path $mount -Force | Out-Null
& $dism /Mount-Image /ImageFile:$wim /Index:1 /MountDir:$mount
Copy-Item "$project\Scripts\*" "$mount\Deploy\Scripts\" -Recurse -Force
Copy-Item "$project\Config\*"  "$mount\Deploy\Config\"  -Recurse -Force
& $dism /Unmount-Image /MountDir:$mount /Commit
```

Then re-upload `boot.wim` to WDS.

### 4.4 — When to Do a Full Rebuild

Use the quick update for script and config changes. Full rebuild when:
- ADK is updated
- WinPE optional components change
- WinPE driver pack is updated
- `startnet.cmd` is changed

---

## Phase 5: Deploy the Boot Image

### 5.1 — WDS (Windows Deployment Services)

1. Open the **WDS Management Console** on your WDS server
2. Expand **Boot Images** → right-click → **Add Boot Image**
3. Browse to `boot.wim`, give it a name like `DynamicPxE - WinPE 11`
4. Complete the wizard

To update: right-click the existing boot image → **Replace Boot Image** → select new `boot.wim`.

### 5.2 — USB Boot (Optional)

For testing or offline deployments:

```cmd
:: From an elevated command prompt, replace X: with your USB drive letter
diskpart
  list disk
  select disk N
  clean
  create partition primary
  active
  format fs=fat32 quick
  assign letter=X
  exit

xcopy /herky "Build\WinPE_x64\media\*" X:\ /e
copy boot.wim X:\sources\boot.wim
```

---

## Phase 6: Running a Deployment

### 6.1 — Boot and Connect

1. PXE boot the target machine (or boot from USB)
2. WinPE loads → the deploy wizard launches automatically
3. The hardware info card shows detected model and service tag
4. Enter share credentials and click **Connect**
5. Image and driver lists populate automatically

### 6.2 — Select and Configure

1. Select an OS image from the list (stock `install.wim`)
2. Verify the auto-selected driver pack is correct (override if needed)
3. The wizard advances to the **Configure** page
4. Review/edit: computer name, domain, OU, product key, timezone, WiFi
5. Review the post-setup apps list (configured in `DeployConfig.json`)
6. Review the deployment summary

### 6.3 — Deploy

1. Click **Next** to reach the Deploy page, then click **Deploy**
2. Read the confirmation dialog — it shows the full summary including disk wipe warning
3. Click **Yes** to begin
4. The sidebar locks — you cannot navigate away during deployment

Typical timing on modern hardware:

| Phase | Duration |
|---|---|
| Disk partitioning | Under 1 minute |
| DISM image apply | 15-40 minutes (depends on image size and network speed) |
| Driver ZIP extraction | 3-8 minutes |
| Driver injection | 2-6 minutes |
| Configuration + boot setup | Under 1 minute |
| **Total** | **20-55 minutes** |

### 6.4 — After Deployment

When deployment completes:
- Progress bar shows 100%
- Machine reboots immediately
- Windows processes `unattend.xml`: sets computer name, joins domain, applies product key, bypasses OOBE, creates local admin account
- `SetupComplete.cmd` runs: imports WiFi profile, installs apps from network share
- Machine is ready for login

**Verify on the deployed machine:**
- `C:\DynamicPxE\Logs\SetupComplete.log` — app install results
- `C:\Deploy_Info.json` — deployment metadata
- `C:\Deploy_Log.txt` — full deployment log
- Device Manager — all drivers should be recognized
- Domain membership — `systeminfo | findstr Domain`

---

## Phase 7: Adding New Hardware Models

### 7.1 — Add the Driver Pack

1. Download the OS driver pack ZIP from your vendor's support site
2. Copy it to `\\your-server\deploy-share\Drivers\`
3. Keep the original filename — the auto-matcher parses it

### 7.2 — Verify the Match

Boot a machine of the new model and connect to the share. The auto-matcher should select the correct pack. If not, add an override to `DriverMap.json`.

### 7.3 — Override Example (DriverMap.json)

```json
{
  "ModelKey": "latitude-5540",
  "ModelDisplay": "Dell Latitude 5540",
  "ZipFile": "win11_latitudee14mlk5540_a08.zip"
}
```

`ModelKey` is the WMI model string lowercased with spaces replaced by hyphens.

---

## Phase 8: Maintenance

### Updating OS Images

Copy new stock `install.wim` files to the share's `Images\` folder. No WIM rebuild needed.

### Updating Driver Packs

Add new ZIPs to the share. The auto-matcher prefers higher revision numbers. Old ZIPs can be left or removed.

### Updating Apps

Edit the `Apps.Packages` array in `DeployConfig.json`, then do a quick update (Phase 4.3) to patch the WIM.

### Updating Scripts

Use the quick update method (Phase 4.3), then re-upload `boot.wim` to WDS.

---

## Appendix A: DISM Commands Reference

```powershell
# Check WIM image info (indexes, edition names)
dism /Get-WimInfo /WimFile:install.wim

# Convert ESD to WIM
dism /Export-Image /SourceImageFile:install.esd /SourceIndex:1 /DestinationImageFile:install.wim /Compress:max

# Check drivers in offline OS
dism /Image:W:\ /Get-Drivers /Format:Table

# Manually apply image from WinPE
dism /Apply-Image /ImageFile:Z:\Images\Win11.wim /Index:1 /ApplyDir:W:\
```

## Appendix B: WinPE Diagnostic Commands

```cmd
:: Network
ipconfig
ping your-server
net use

:: Disks
diskpart -> list disk
wmic logicaldisk get caption,size,freespace,drivetype

:: Hardware
wmic csproduct get name,vendor,identifyingnumber

:: Logs
type X:\Deploy\Logs\deploy.log

:: Manually launch GUI
powershell.exe -ExecutionPolicy Bypass -File X:\Deploy\Scripts\GUI\Start-DeployGUI.ps1
```
