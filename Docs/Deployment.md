# Dell Image Assist — Build & Deployment Guide

This document covers everything from initial setup through your first successful deployment. Follow the phases in order. Estimated time for a first-time build: 45–90 minutes. Subsequent builds after updating scripts: under 10 minutes.

---

## Phase 1: Prerequisites & Project Setup

### 1.1 — Software Required on the Build Machine

The build machine is a Windows 10 or Windows 11 x64 workstation — **not** a target Dell machine. You need Administrator access on it.

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

**Dell WinPE Driver Pack (CAB file)**

1. Go to: https://www.dell.com/support/kbdoc/en-us/000108728
2. On that page, search or scroll for **"WinPE 11"** — you want the WinPE-specific pack, not the OS driver packs
3. Download the CAB file — it will be named something like `WinPE11.0-Drivers-A01-6WNKN.cab`
4. **Do not place this CAB in your project folder yet** — it must be extracted first (see step 1.4)

> **WinPE CAB vs OS driver ZIPs — what is the difference?**
>
> | | WinPE Driver Pack (CAB) | OS Driver Packs (ZIPs) |
> |---|---|---|
> | Purpose | Lets WinPE see the disk and NIC at boot | Installs drivers into deployed Windows |
> | Where it goes | Extracted into `DellWinPEDrivers\` on build machine | Placed as-is on the network share |
> | Extraction | You extract it manually once at build time | System extracts automatically at deploy time |
> | How many | One universal pack covers all Dell models | One ZIP per model family |

---

### 1.2 — Create the Project Folder

Open an **elevated command prompt** (right-click Command Prompt, Run as Administrator) and run these commands:

```cmd
:: Create the project root
mkdir C:\DynamicPxE

:: Create all required subfolders
mkdir C:\DynamicPxE\Build
mkdir C:\DynamicPxE\Build\Mount
mkdir C:\DynamicPxE\Scripts
mkdir C:\DynamicPxE\Scripts\Core
mkdir C:\DynamicPxE\Scripts\Dell
mkdir C:\DynamicPxE\Scripts\GUI
mkdir C:\DynamicPxE\Scripts\Logging
mkdir C:\DynamicPxE\Config
mkdir C:\DynamicPxE\Docs
mkdir C:\DynamicPxE\DellWinPEDrivers
```

You should now have this structure (all folders empty):

```
C:\DynamicPxE\
├── Build\
│   └── Mount\
├── Scripts\
│   ├── Core\
│   ├── Dell\
│   ├── GUI\
│   └── Logging\
├── Config\
├── Docs\
└── DellWinPEDrivers\
```

---

### 1.3 — Copy the Project Files

Copy all files from this repository into `C:\DynamicPxE\` maintaining the folder structure. The easiest way is to copy the entire repo contents directly into `C:\DynamicPxE\`.

After copying, verify the key files are in place:

```cmd
dir C:\DynamicPxE\Build-WinPE.ps1
dir C:\DynamicPxE\startnet.cmd
dir C:\DynamicPxE\Scripts\GUI\Start-DeployGUI.ps1
dir C:\DynamicPxE\Scripts\Core\Invoke-Deployment.ps1
dir C:\DynamicPxE\Config\DellDriverMap.json
```

All five should show file sizes. If any say "File Not Found" the copy was incomplete — check the folder structure.

---

### 1.4 — Extract the Dell WinPE Driver CAB

The CAB file downloaded in step 1.1 must be extracted into `DellWinPEDrivers\` before building. DISM cannot inject drivers directly from a CAB — it requires loose INF and SYS files in a folder.

From your elevated command prompt, run `expand.exe` with the `-F:*` flag to extract all files:

```cmd
:: Replace the filename below with your actual downloaded CAB filename
expand.exe -F:* "C:\Users\YourName\Downloads\WinPE11.0-Drivers-A01-6WNKN.cab" C:\DynamicPxE\DellWinPEDrivers
```

This takes 1–3 minutes. When complete, verify the extraction worked:

```cmd
dir C:\DynamicPxE\DellWinPEDrivers
```

You should see subfolders like this:

```
C:\DynamicPxE\DellWinPEDrivers\
├── network\
│   └── (Intel/Realtek NIC .inf and .sys files)
├── storage\
│   └── (NVMe, VMD controller .inf and .sys files)
├── video\
│   └── (display drivers)
└── ... (other categories)
```

> **The two most critical subfolders are `storage\` and `network\`.** Without storage drivers WinPE cannot see the NVMe SSD on modern Dell hardware. Without network drivers WinPE cannot reach the deployment share. If either folder is empty after extraction the CAB may be corrupt — re-download it.

The original CAB file can be deleted or archived after extraction. You only need the extracted contents.

---

### 1.5 — Verify ADK Installation

Confirm the ADK and WinPE Add-on both installed correctly before attempting a build:

```cmd
:: Must exist — proves WinPE Add-on is installed
dir "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\en-us\winpe.wim"

:: Must exist — proves ADK Deployment Tools are installed
dir "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\DandISetEnv.bat"
```

Both files must be present. If either is missing, re-run the corresponding installer.

---

### 1.6 — Final Pre-Build Checklist

Before proceeding to Phase 3, your `C:\DynamicPxE\` folder must contain all of the following:

```
C:\DynamicPxE\
├── Build-WinPE.ps1                     ✅ from this repo
├── startnet.cmd                        ✅ from this repo
├── Scripts\
│   ├── Core\
│   │   ├── Apply-Image.ps1             ✅ from this repo
│   │   ├── Expand-DriverPack.ps1       ✅ from this repo
│   │   ├── Inject-Drivers.ps1          ✅ from this repo
│   │   ├── Invoke-Deployment.ps1       ✅ from this repo
│   │   └── Map-NetworkShare.ps1        ✅ from this repo
│   ├── Dell\
│   │   ├── Get-DellDriverPack.ps1      ✅ from this repo
│   │   └── Get-DellModel.ps1           ✅ from this repo
│   ├── GUI\
│   │   └── Start-DeployGUI.ps1         ✅ from this repo
│   └── Logging\
│       └── Write-DeployLog.ps1         ✅ from this repo
├── Config\
│   └── DellDriverMap.json              ✅ from this repo
├── Docs\
│   ├── Deployment.md                   ✅ from this repo
│   └── Reference.md                    ✅ from this repo
├── Build\
│   └── Mount\                          ✅ empty folder (build workspace)
└── DellWinPEDrivers\
    ├── network\                        ✅ extracted from Dell WinPE CAB
    ├── storage\                        ✅ extracted from Dell WinPE CAB
    └── ...                             ✅ other categories from CAB
```

If everything is in place, proceed to Phase 2 (network share setup) then Phase 3 (build).

---

## Phase 2: Prepare the Network Share

### 2.1 — Create the Share Folder Structure

On the server at `your-server`, create the following folder structure:

```
D:\Dell\Image_Assist\           (or whatever local path you prefer)
    Images\
    Drivers\
```

Share the `Image_Assist` folder as `Image_Assist` and set the share path to `\\your-server\your-share`.

### 2.2 — Set Share Permissions

**Share permissions:** The deployment service account needs at minimum `Read` access.  
**NTFS permissions:** `Read & Execute` on `Image_Assist` and all subfolders.

Use a dedicated service account (e.g. `DOMAIN\svc-winpe-deploy`) rather than a personal account. This account's credentials will be entered by technicians at the GUI prompt each deployment.

No write permissions are needed. WinPE reads images and drivers from the share but writes nothing back.

### 2.3 — Add OS Images

Place your Windows 11 WIM files in the `Images\` folder:

```
\\your-server\your-share\Images\
    Win11_24H2_Enterprise_x64.wim
    Win11_23H2_Enterprise_x64.wim
```

**Dell Image Assist WIM structure:**

WIMs captured with Dell Image Assist contain 5 indexes. Only index 2 is the actual Windows OS:

| Index | Description | Deploy? |
|---|---|---|
| 1 | System — Dell IA metadata | ❌ |
| 2 | Windows_IW — **the OS** | ✅ Always use this |
| 3 | Recovery — placeholder (0 bytes) | ❌ |
| 4 | Summary_IA — Dell IA metadata | ❌ |
| 5 | Logs — Dell IA capture logs | ❌ |

The GUI auto-detects this structure. When you select a Dell IA WIM, the index field automatically changes to 2 and the image info label turns green to confirm. You do not need to set this manually.

**General WIM tips:**
- File names become the display names in the GUI — use descriptive names.
- Organize WIMs into subfolders under `Images\` if needed (e.g. `ImagesH2\`, `ImagesH2\`). The GUI enumerates recursively.
- SWM (split WIM) files are supported. Place all `.swm` parts in the same folder. Select the first part in the GUI — DISM finds the rest automatically.
- Verify a WIM's index structure before deploying: `dism /Get-WimInfo /WimFile:"path	oile.wim"`

### 2.4 — Add Driver Packs

Place Dell driver ZIP files directly in the `Drivers\` folder:

```
\\your-server\your-share\Drivers\
    Win11_latitudee5550_a19.zip
    win11_optiplexd13mlk7020_a17.zip
    win11_latitudee14mlk5530_a16.zip
    win11_latitudee13tgl5520_a18.zip
    win11_optiplexd11_a21.zip
    win11_optiplexd12_a14.zip
    win11_precisionm11tgl3560_a19.zip
    ... (add more as needed)
```

**Naming requirements:** Keep Dell's original filenames exactly. The auto-matching engine parses the filename to extract OS, model token, and revision. Renaming ZIPs will break auto-matching.

**Which pack for which model:**

| Dell WMI Model String | Recommended ZIP |
|---|---|
| Latitude 5550 | `Win11_latitudee5550_a19.zip` |
| Latitude 5530 | `win11_latitudee14mlk5530_a16.zip` |
| Latitude 5520 | `win11_latitudee13tgl5520_a18.zip` |
| Latitude 5320 | `win11_latitudee13tgl5320_a17.zip` |
| OptiPlex 7020 | `win11_optiplexd13mlk7020_a17.zip` |
| OptiPlex 7010 | `win11_optiplexd12_a14.zip` |
| OptiPlex 7000 | `win11_optiplexd11_a21.zip` |
| Precision 3560 | `win11_precisionm11tgl3560_a19.zip` |

**Keeping packs up to date:** When Dell releases a newer revision (e.g. `a20` replaces `a17`), simply add the new ZIP to the share. The auto-matcher will prefer the higher revision automatically. You can leave old ZIPs on the share or delete them — either is fine.

---

## Phase 3: Build the WinPE Boot Image

### 3.1 — Open an Elevated PowerShell Prompt

Right-click **Windows PowerShell** and choose **Run as Administrator**. All build operations require elevation.

If you see an execution policy error when running the script, run this first:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### 3.2 — Run the Build Script

Navigate to your project folder and run the build script:

```powershell
cd C:\DynamicPxE
.\Build-WinPE.ps1
```

The script runs 9 numbered steps and prints color-coded output — cyan for each step, green for success, yellow for warnings, red for errors. Each step is verified before moving to the next so nothing fails silently.

The 9 steps are:

1. **Environment setup** — cleans any stale mounts, creates the `Build\` folder structure
2. **Copy WinPE media** — stages `Boot\`, `EFI\`, `bootmgr`, and `en-us\` from the ADK `Media\` folder
3. **Stage and mount boot.wim** — copies `winpe.wim` from the ADK into `sources\boot.wim` and mounts it
4. **Install optional components** — adds WMI, NetFX, PowerShell, HTA, StorageWMI, networking, and GUI packages
5. **Configure settings** — sets 512 MB scratch space, Eastern Standard Time, and PowerShell execution policy
6. **Inject scripts** — copies all deployment scripts, config, and `startnet.cmd` into the WIM
7. **Inject Dell WinPE drivers** — injects all INF/SYS files from `DellWinPEDrivers\` recursively
8. **Verify** — confirms script count and `startnet.cmd` are present in the image
9. **Unmount and save** — commits changes and copies the final `boot.wim` to the project root

**Expected runtime:** 10–25 minutes depending on machine speed.

**Expected output at completion:**
```
============================================================
  BUILD COMPLETE  -  XXXX MB
  C:\DynamicPxE\boot.wim
============================================================
```

The finished `boot.wim` will be at `C:\DynamicPxE\boot.wim`. This is the file you upload to WDS in Phase 4.

### 3.3 — If the Build Fails

The most common failures and their fixes:

**"winpe.wim not found"** — The WinPE Add-on was not installed, or was installed to a non-default path. Verify this file exists:
`C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\en-us\winpe.wim`

**"ADK dism.exe not found"** — The ADK Deployment Tools were not installed. Re-run the ADK installer and select Deployment Tools.

**DISM component install warnings** — Some optional components may not be available in all ADK versions. The script treats these as non-fatal warnings and continues. Check the DISM log at `C:\Windows\Logs\DISM\dism.log` to confirm critical components installed.

**Script fails partway through** — A stale WIM mount is the most common cause. Clean up and retry:

```powershell
# Run from elevated PowerShell in C:\DynamicPxE
& "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\AMD64\DISM\dism.exe" /Cleanup-Mountpoints
Remove-Item C:\DynamicPxE\Build\Mount    -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item C:\DynamicPxE\Build\WinPE_x64 -Recurse -Force -ErrorAction SilentlyContinue
.\Build-WinPE.ps1
```

### 3.4 — Updating Scripts Without a Full Rebuild

If you update any PowerShell scripts or `DellDriverMap.json`, you do not need to fully rebuild. Mount the existing WIM, copy the updated files in, and unmount. Run from an **elevated PowerShell** prompt:

```powershell
$dism    = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\AMD64\DISM\dism.exe"
$wim     = "C:\DynamicPxE\boot.wim"
$mount   = "C:\DynamicPxE\Build\Mount"
$project = "C:\DynamicPxE"

# Create mount folder if it doesn't exist
New-Item -ItemType Directory -Path $mount -Force | Out-Null

# Mount
& $dism /Mount-Image /ImageFile:$wim /Index:1 /MountDir:$mount

# Copy updated scripts and config
Copy-Item "$project\Scripts\*" "$mount\Deploy\Scripts\" -Recurse -Force
Copy-Item "$project\Config\*"  "$mount\Deploy\Config\"  -Recurse -Force

# Unmount and save
& $dism /Unmount-Image /MountDir:$mount /Commit
```

Then re-upload `boot.wim` to WDS (Replace Boot Image).

### 3.5 — When to Do a Full Rebuild

Use the quick update above for script and config changes. Do a full rebuild (`.\Build-WinPE.ps1`) when:

- The ADK is updated to a new version
- New WinPE optional components need to be added
- The Dell WinPE driver CAB is updated
- `startnet.cmd` is changed

---

## Phase 4: Deploy the Boot Image to WDS / PXE

### 4.1 — WDS (Windows Deployment Services)

If using WDS on your network:

1. Open the **WDS Management Console** on your WDS server
2. Expand **Boot Images**
3. Right-click → **Add Boot Image**
4. Browse to your newly built `boot.wim`
5. Give it a descriptive name: `Dell Image Assist - WinPE 11 24H2`
6. Complete the wizard

To replace an existing boot image:
1. Right-click the existing Dell Image Assist boot image → **Replace Boot Image**
2. Select the new `boot.wim`

### 4.2 — PXE Without WDS

If using a Linux-based PXE server (TFTP + iPXE or PXELINUX):

1. Copy `boot.wim` to your TFTP server
2. You also need `boot.sdi` and a bootable PE environment loader. These come from the ADK at:
   `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\Media\Boot\`
3. Configure your iPXE or PXELINUX menu entry to chainload the Windows boot manager (`bootmgr.exe`) pointing at the WIM

For simplicity, WDS is the recommended PXE method for Windows-based deployments.

### 4.3 — USB Boot (Optional)

To boot from USB instead of PXE for testing or offline deployments:

```cmd
:: From an elevated command prompt on the build machine:
:: Replace X: with your USB drive letter

diskpart
  list disk
  select disk N        :: select your USB drive
  clean
  create partition primary
  active
  format fs=fat32 quick
  assign letter=X
  exit

:: Copy WinPE boot files to USB
xcopy /herky "Build\WinPE_x64\media\*" X:\ /e
copy boot.wim X:\sources\boot.wim
```

---

## Phase 5: First Boot Test

Before deploying to production machines, test the WinPE boot on a lab machine or VM.

### 5.1 — What to Expect at Boot

1. Machine PXE boots → WDS serves `boot.wim`
2. WinPE loads (blue progress bar, then blank screen briefly)
3. `startnet.cmd` runs:
   - `wpeinit` initializes network and hardware (~5–15 seconds)
   - PowerShell launches `Start-DeployGUI.ps1`
4. The **Dell Image Assist** GUI appears in 1920×1080 dark theme
5. The top of the GUI shows the detected Dell model and service tag

If the GUI does not appear after 60 seconds, see the troubleshooting section in `Reference.md`.

### 5.2 — Verify Hardware Detection

The GUI header should show the exact Dell model. Compare it against what WMI returns:

```powershell
# From WinPE PowerShell (Shift+F10 during boot to open cmd, then powershell.exe)
(Get-CimInstance Win32_ComputerSystem).Model
```

Confirm the displayed model matches. If it shows "Unknown" or a generic string, WMI is not available — the WinPE-WMI component did not install correctly.

### 5.3 — Connect to the Share

1. Enter the service account credentials in the **Username** and **Password** fields
   - Format: `DOMAIN\svc-winpe-deploy` or just `svc-winpe-deploy` for local accounts
2. Click **Connect**
3. The status label should turn green: `✓ Connected (Z:)`
4. The image list and driver pack list should populate

If the connection fails, verify network connectivity with `ping your-server` from the WinPE command prompt (Shift+F10).

### 5.4 — Verify Auto-Match

After connecting, look at the **Driver Pack Selection** panel. The auto-matched pack should be highlighted with a green note showing the match type and pack name. Confirm the matched pack is the correct one for the machine model.

The deployment log panel at the bottom right shows the full scoring output — you can see every ZIP's score, OS preference, and revision that was evaluated.

---

## Phase 6: Running a Deployment

### 6.1 — Pre-Deployment Checklist

Before clicking Start Deployment on a production machine:

- [ ] Confirm the correct OS image is selected
- [ ] Confirm the auto-matched driver pack is correct for this model
- [ ] Confirm the Image Index is correct (Dell Image Assist WIMs = **always 2**; the GUI sets this automatically)
- [ ] Confirm Target Disk 0 is the correct disk (on machines with multiple drives, verify in BIOS or with `diskpart` before booting)
- [ ] Confirm all data on the target machine has been backed up — the disk will be completely erased

### 6.2 — Starting Deployment

1. Select the OS image from the image list
2. Verify the driver pack selection (override if needed)
3. Set Image Index if not 1
4. Click **🚀 START DEPLOYMENT**
5. Read the confirmation dialog — it shows the full deployment summary
6. Click **Yes** to begin

### 6.3 — During Deployment

The progress bar and status label update throughout. The log panel shows real-time output. Typical times for each phase on a modern Dell machine:

| Phase | Typical Duration |
|---|---|
| Disk partitioning | Under 1 minute |
| ZIP extraction (to RAM disk) | 3–8 minutes (varies by pack size — 2–4 GB) |
| DISM image apply | 15–40 minutes (depends on image size and NIC speed) |
| Driver injection | 2–6 minutes |
| BCDboot + cleanup | Under 1 minute |
| **Total** | **20–55 minutes** |

Do not power off the machine during deployment. If the machine appears frozen, check the log panel — DISM apply does not update the progress bar in real time but is running.

### 6.4 — After Deployment

When deployment completes:
- Progress bar shows 100%
- Status reads: `✓ Deployment successful! Rebooting in 15 seconds...`
- The machine reboots automatically after the countdown

On first boot into Windows 11:
- Windows will run hardware detection using the pre-injected drivers
- A 3–5 minute setup phase is normal for Windows to complete first-run configuration
- No drivers should appear as "Unknown" in Device Manager for supported Dell hardware

---

## Phase 7: Adding New Models

When you need to support a Dell model that isn't on the share yet:

### 7.1 — Find the Correct Driver Pack

1. Go to https://www.dell.com/support/kbdoc/en-us/000108728
2. Select your model and Windows 11 as the OS
3. Download the "Driver Pack" (not individual drivers — you want the full family pack ZIP)
4. Verify the filename follows Dell's naming convention: `win11_{familytoken}_{revision}.zip`

### 7.2 — Identify the WMI Model Key (Optional but Useful)

Boot the target machine into WinPE and run:

```powershell
(Get-CimInstance Win32_ComputerSystem).Model
```

This tells you exactly what string the auto-scorer will try to match. If the model number appears in the ZIP's filename token, auto-matching will work without any JSON changes.

For example, if WMI returns `"Latitude 5540"` and the ZIP is `win11_latitudee14mlk5540_a08.zip`, the token `latitudee14mlk5540` contains `5540`, which matches the WMI model number — auto-match will work.

### 7.3 — Add the ZIP to the Share

Copy the downloaded ZIP directly to `\\your-server\your-share\Drivers\`. No renaming, no extraction. The next WinPE boot will include it in the scoring pool.

### 7.4 — Verify the Match

Boot a machine of the new model, connect to the share, and check the driver pack auto-match. If it selects the correct pack, you're done.

If the wrong pack is selected (or no match is found), add an explicit entry to `DellDriverMap.json`:

```json
{
  "ModelKey": "latitude-5540",
  "ModelDisplay": "Dell Latitude 5540",
  "ZipFile": "win11_latitudee14mlk5540_a08.zip",
  "DriverFolder": "",
  "Notes": ""
}
```

`ModelKey` must be the WMI model string lowercased with spaces replaced by hyphens. After editing the JSON, use the quick update procedure from Phase 3.4 to patch the running `boot.wim` without a full rebuild.

---

## Phase 8: Maintenance

### Updating Driver Packs

When Dell releases a newer pack revision:

1. Download the new ZIP from Dell's driver pack page
2. Copy it to `\\your-server\your-share\Drivers\`
3. The next deployment will automatically select the newer revision (higher `a` number wins)
4. Optionally delete the old ZIP to keep the share clean — the GUI list shows all ZIPs, and a cluttered list makes manual selection harder

### Updating OS Images

When you recapture your reference image or receive a new WIM:

1. Copy the new WIM to `\\your-server\your-share\Images\`
2. If replacing an existing image, delete the old file or rename it clearly (e.g. append `_old`)
3. No WIM rebuild is needed — images are loaded from the share at runtime

### Updating Scripts

When scripts are updated:

1. Copy the updated `.ps1` files into `C:\DynamicPxE\Scripts\`
2. Use the quick update method from Phase 3.4 to patch the existing `boot.wim`
3. Re-upload `boot.wim` to WDS (Replace Boot Image)

No full rebuild needed for script-only changes.

### Rebuilding from Scratch

Run `.\Build-WinPE.ps1` from an elevated PowerShell when:

- The ADK is updated to a new version
- New WinPE optional components need to be added
- The Dell WinPE CAB driver pack is updated
- `startnet.cmd` is changed

Full rebuild time: 10–25 minutes.

---

## Appendix A: DISM Commands Reference

Useful DISM commands to run manually from the build machine or WinPE:

```powershell
# Check WIM image info (indexes, edition names)
dism /Get-WimInfo /WimFile:boot.wim

:: Check installed packages in mounted WIM
dism /Get-Packages /Image:Build\Mount

:: Check injected drivers in mounted WIM
dism /Get-Drivers /Image:Build\Mount

:: Verify WIM is not corrupted
dism /Check-ImageHealth /ImageFile:Win11.wim

:: Check drivers injected into offline OS (from WinPE after apply)
dism /Image:W:\ /Get-Drivers /Format:Table

:: Manually apply image (from WinPE for testing)
dism /Apply-Image /ImageFile:Z:\Images\Win11.wim /Index:1 /ApplyDir:W:\
```

---

## Appendix B: diskpart Reference

```cmd
:: List all physical disks
list disk

:: View partition layout on disk 0
select disk 0
list partition

:: Clean a disk and start fresh (DESTRUCTIVE)
select disk 0
clean

:: Check disk 0 attributes
select disk 0
detail disk
```

---

## Appendix C: WinPE Diagnostic Commands

```cmd
:: Check IP address and network connectivity
ipconfig
ping your-server

:: View mapped drives
net use

:: Check physical disks
diskpart → list disk

:: View all drive letters and sizes
wmic logicaldisk get caption,size,freespace,drivetype

:: Get Dell model info
wmic csproduct get name,vendor,identifyingnumber

:: Check PowerShell availability
powershell.exe -Command "Get-Host"

:: Read the deployment log
type X:\Deploy\Logs\deploy.log

:: Manually launch GUI
powershell.exe -ExecutionPolicy Bypass -File X:\Deploy\Scripts\GUI\Start-DeployGUI.ps1
```
