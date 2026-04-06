#Requires -RunAsAdministrator
# ============================================================
#  Build-WinPE.ps1
#  Builds a custom WinPE boot.wim using Windows ADK 26100
#
#  Run from an elevated PowerShell prompt:
#    cd C:\DynamicPxE
#    .\Build-WinPE.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

# ── Configuration ─────────────────────────────────────────────
$ADKPath     = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
$WinPEADK    = Join-Path $ADKPath "Windows Preinstallation Environment"
$DeployTools = Join-Path $ADKPath "Deployment Tools"
$Arch        = "amd64"

$ProjectRoot = $PSScriptRoot
$WorkDir     = Join-Path $ProjectRoot "Build"
$MountDir    = Join-Path $WorkDir "Mount"
$StageDir    = Join-Path $WorkDir "WinPE_x64"
$MediaDir    = Join-Path $StageDir "media"
$SourcesDir  = Join-Path $MediaDir "sources"
$OutputWim   = Join-Path $ProjectRoot "boot.wim"

$WinPEWim    = Join-Path $WinPEADK "$Arch\en-us\winpe.wim"
$WinPEOCs    = Join-Path $WinPEADK "$Arch\WinPE_OCs"
$MediaSrc    = Join-Path $WinPEADK "$Arch\Media"

# Always use the ADK dism.exe — not the inbox one
$DismExe     = Join-Path $DeployTools "AMD64\DISM\dism.exe"

$ScriptsSrc  = Join-Path $ProjectRoot "Scripts"
$ConfigSrc   = Join-Path $ProjectRoot "Config"
$DriversDir  = Join-Path $ProjectRoot "WinPEDrivers"

# ── Helpers ───────────────────────────────────────────────────
function Write-Step { param($n, $msg) Write-Host "" ; Write-Host "[$n/9] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "      $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "      WARNING: $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "      ERROR: $msg" -ForegroundColor Red }

# Run DISM with explicit argument array - no string splitting, no cmd /c
# Each argument is a separate array element passed directly to the exe
function Invoke-Dism {
    param([string[]]$DismArgs)
    $output = & $DismExe @DismArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errLines = $output | Where-Object { $_ -match 'Error|error' } | Select-Object -First 5
        throw "DISM failed (exit $LASTEXITCODE)`n$($errLines -join "`n")"
    }
}

function Add-WinPEPackage {
    param([string]$PackageName)
    $cab = Join-Path $WinPEOCs "$PackageName.cab"
    if (-not (Test-Path $cab)) { Write-Warn "$PackageName.cab not found - skipping"; return }

    Write-Host "      Adding $PackageName..." -NoNewline
    Invoke-Dism @("/Image:$MountDir", "/Add-Package", "/PackagePath:$cab", "/Quiet")
    Write-Host " OK" -ForegroundColor Green

    $langCab = Join-Path $WinPEOCs "en-us\${PackageName}_en-us.cab"
    if (Test-Path $langCab) {
        Invoke-Dism @("/Image:$MountDir", "/Add-Package", "/PackagePath:$langCab", "/Quiet")
    }
}

# ══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DynamicPxE - Build Script" -ForegroundColor Cyan
Write-Host "  ADK 26100 / Windows 11 24H2" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Prerequisites ─────────────────────────────────────────────
Write-Host "Checking prerequisites..."

if (-not (Test-Path $WinPEWim))    { Write-Err "winpe.wim not found: $WinPEWim"; exit 1 }
Write-OK "winpe.wim found"

if (-not (Test-Path $DismExe))     { Write-Err "ADK dism.exe not found: $DismExe"; exit 1 }
Write-OK "ADK dism.exe found: $DismExe"

if (-not (Test-Path $MediaSrc))    { Write-Err "ADK Media folder not found: $MediaSrc"; exit 1 }
Write-OK "ADK Media folder found"

# ── Step 1: Clean and create build folders ────────────────────
Write-Step 1 "Setting up build environment..."

if (Test-Path $MountDir) {
    Write-Host "      Cleaning stale mount point..."
    & $DismExe /Unmount-Image /MountDir:$MountDir /Discard 2>$null | Out-Null
    Start-Sleep -Seconds 2
    Remove-Item $MountDir -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path $StageDir) {
    Remove-Item $StageDir -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($dir in @($MountDir, $StageDir, $MediaDir, $SourcesDir,
                   (Join-Path $MediaDir "Boot"),
                   (Join-Path $MediaDir "EFI"))) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
Write-OK "Build folders created"

# ── Step 2: Stage WinPE media ─────────────────────────────────
Write-Step 2 "Copying base WinPE files..."

Copy-Item (Join-Path $MediaSrc "Boot")        (Join-Path $MediaDir "Boot")        -Recurse -Force
Write-OK "Boot\ copied"
Copy-Item (Join-Path $MediaSrc "EFI")         (Join-Path $MediaDir "EFI")         -Recurse -Force
Write-OK "EFI\ copied"
Copy-Item (Join-Path $MediaSrc "bootmgr")     (Join-Path $MediaDir "bootmgr")     -Force
Copy-Item (Join-Path $MediaSrc "bootmgr.efi") (Join-Path $MediaDir "bootmgr.efi") -Force
Write-OK "bootmgr files copied"
if (Test-Path (Join-Path $MediaSrc "en-us")) {
    Copy-Item (Join-Path $MediaSrc "en-us") (Join-Path $MediaDir "en-us") -Recurse -Force
    Write-OK "en-us\ copied"
}

# ── Step 3: Stage and mount boot.wim ──────────────────────────
Write-Step 3 "Staging and mounting boot.wim..."

$stagedWim = Join-Path $SourcesDir "boot.wim"
Write-Host "      Copying winpe.wim -> sources\boot.wim..."
Copy-Item $WinPEWim $stagedWim -Force
Write-OK "winpe.wim staged ($([math]::Round((Get-Item $stagedWim).Length/1MB,1)) MB)"

Write-Host "      Mounting boot.wim (this takes about a minute)..."
Invoke-Dism @(
    "/Mount-Image",
    "/ImageFile:$stagedWim",
    "/Index:1",
    "/MountDir:$MountDir"
)
Write-OK "boot.wim mounted at $MountDir"

# ── Step 4: Install WinPE optional components ─────────────────
Write-Step 4 "Installing optional components..."

foreach ($pkg in @(
    "WinPE-WMI", "WinPE-NetFX", "WinPE-Scripting", "WinPE-PowerShell",
    "WinPE-StorageWMI", "WinPE-DismCmdlets", "WinPE-EnhancedStorage",
    "WinPE-Dot3Svc", "WinPE-RNDIS",
    "WinPE-HTA", "WinPE-FontSupport-WinRE", "WinPE-SecureStartup"
)) { Add-WinPEPackage $pkg }

# ── Step 5: Configure WinPE settings ──────────────────────────
Write-Step 5 "Configuring WinPE settings..."

Invoke-Dism @("/Image:$MountDir", "/Set-ScratchSpace:512")
Write-OK "Scratch space: 512 MB"

# Read timezone from DeployConfig.json if available
$configFile = Join-Path $ProjectRoot "Config\DeployConfig.json"
$timezone   = "Eastern Standard Time"
if (Test-Path $configFile) {
    try {
        $cfg      = Get-Content $configFile -Raw | ConvertFrom-Json
        $timezone = $cfg.Deployment.Timezone
    } catch { }
}
Invoke-Dism @("/Image:$MountDir", "/Set-TimeZone:$timezone")
Write-OK "Timezone: $timezone"

# Set PowerShell execution policy via offline registry hive
Write-Host "      Setting PowerShell execution policy..."
$hivePath = Join-Path $MountDir "Windows\System32\config\SOFTWARE"
$regKey   = "HKLM\WinPE_SOFTWARE"
reg load $regKey $hivePath | Out-Null
reg add "$regKey\Policies\Microsoft\Windows\PowerShell" /v ExecutionPolicy /t REG_SZ /d Unrestricted /f | Out-Null
[gc]::Collect()   # force handle release before unload
Start-Sleep -Seconds 1
reg unload $regKey | Out-Null
Write-OK "PowerShell ExecutionPolicy: Unrestricted"

# ── Step 6: Inject deployment scripts ─────────────────────────
Write-Step 6 "Injecting deployment scripts..."

$peRoot = Join-Path $MountDir "Deploy"
foreach ($dir in @(
    "$peRoot\Scripts\Core",     "$peRoot\Scripts\Hardware",
    "$peRoot\Scripts\GUI",      "$peRoot\Scripts\Logging",
    "$peRoot\Config",           "$peRoot\Logs"
)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

Copy-Item (Join-Path $ScriptsSrc "*") (Join-Path $peRoot "Scripts") -Recurse -Force
Copy-Item (Join-Path $ConfigSrc  "*") (Join-Path $peRoot "Config")  -Recurse -Force

$sys32 = Join-Path $MountDir "Windows\System32"
if (-not (Test-Path $sys32)) { Write-Err "$sys32 not found - WIM mount may have failed"; exit 1 }
Copy-Item (Join-Path $ProjectRoot "startnet.cmd") (Join-Path $sys32 "startnet.cmd") -Force

# Copy Resources folder (logos, icons) if it exists
$ResourcesSrc = Join-Path $ProjectRoot "Resources"
if (Test-Path $ResourcesSrc) {
    $ResourcesDst = Join-Path $peRoot "Resources"
    New-Item -ItemType Directory -Path $ResourcesDst -Force | Out-Null
    Copy-Item (Join-Path $ResourcesSrc "*") $ResourcesDst -Recurse -Force
    Write-OK "Resources folder injected"
} else {
    Write-Warn "No Resources\ folder found - logos and icons will not be available"
    Write-Warn "Create C:\DynamicPxE\Resources\ and add logo.png / icon.ico"
}

Write-OK "Scripts, config, and startnet.cmd injected"

$psProfileDir = Join-Path $MountDir "Windows\System32\WindowsPowerShell\v1.0"
New-Item -ItemType Directory -Path $psProfileDir -Force | Out-Null
@'
# DynamicPxE - PowerShell profile
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
'@ | Set-Content (Join-Path $psProfileDir "profile.ps1") -Encoding UTF8
Write-OK "PowerShell profile written"

# ── Step 7: Inject WinPE drivers ──────────────────────────────
Write-Step 7 "Injecting WinPE drivers..."

if (Test-Path $DriversDir) {
    $infCount = (Get-ChildItem $DriversDir -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue).Count
    if ($infCount -gt 0) {
        Write-Host "      Found $infCount INF files - injecting..."
        try {
            Invoke-Dism @("/Image:$MountDir", "/Add-Driver", "/Driver:$DriversDir", "/Recurse", "/ForceUnsigned")
            Write-OK "WinPE drivers injected"
        } catch {
            Write-Warn "Some drivers failed to inject - build will continue."
            Write-Warn "Verify NIC and storage work on first WinPE boot."
        }
    } else {
        Write-Warn "WinPEDrivers\ is empty. Extract your WinPE driver CAB first."
        Write-Warn "Example: expand.exe -F:* <YourWinPE.cab> .\WinPEDrivers\"
    }
} else {
    Write-Warn "WinPEDrivers\ not found. WinPE may not detect NIC or NVMe storage."
    Write-Warn "Create WinPEDrivers\ and extract your vendor's WinPE driver CAB into it."
}

# ── Step 8: Verify ────────────────────────────────────────────
Write-Step 8 "Verifying injected content..."

$scriptCount = (Get-ChildItem (Join-Path $peRoot "Scripts") -Filter "*.ps1" -Recurse).Count
Write-OK "$scriptCount PowerShell scripts in image"
$startnetPresent = Test-Path (Join-Path $sys32 "startnet.cmd")
Write-OK "startnet.cmd: $(if ($startnetPresent) {'present'} else {'MISSING'})"

# ── Step 9: Unmount and save ───────────────────────────────────
Write-Step 9 "Unmounting and saving WIM..."

Write-Host "      Committing changes (this takes a few minutes)..."
Invoke-Dism @("/Unmount-Image", "/MountDir:$MountDir", "/Commit")
Write-OK "WIM unmounted and committed"

Copy-Item $stagedWim $OutputWim -Force
$finalMB = [math]::Round((Get-Item $OutputWim).Length / 1MB, 1)
Write-OK "boot.wim -> $OutputWim ($finalMB MB)"

# ── Done ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  BUILD COMPLETE  -  $finalMB MB" -ForegroundColor Green
Write-Host "  $OutputWim" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  1. WDS Console > Boot Images > Add Boot Image (or Replace)"
Write-Host "  2. Images:  Place stock install.wim files in your share Images\ folder"
Write-Host "  3. Drivers: Place driver ZIPs in your share Drivers\ folder"
Write-Host "  4. PXE boot a machine - the deploy wizard launches automatically"
Write-Host ""
