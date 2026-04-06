#Requires -RunAsAdministrator
# ============================================================
#  Repair-Build.ps1
#  Cleans up stale WIM mounts and build artifacts left behind
#  by an interrupted or failed Build-WinPE.ps1 run.
#
#  Run this whenever Build-WinPE.ps1 fails at step 3/9 or
#  you see "The directory is not empty" / mount errors.
#
#  Usage:
#    Right-click PowerShell -> Run as Administrator
#    cd C:\DynamicPxE
#    .\Repair-Build.ps1
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'

$ADKPath  = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
$DismExe  = "$ADKPath\Deployment Tools\AMD64\DISM\dism.exe"
$MountDir = "$PSScriptRoot\Build\Mount"
$StageDir = "$PSScriptRoot\Build\WinPE_x64"

if (-not (Test-Path $DismExe)) { $DismExe = "dism.exe" }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DynamicPxE - Build Repair" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Discard any mounted image at the mount dir
Write-Host "Step 1: Discarding any mounted WIM at Build\Mount..." -ForegroundColor Cyan
& $DismExe /Unmount-Image /MountDir:"$MountDir" /Discard 2>$null | Out-Null
Write-Host "      Done." -ForegroundColor Green

# Step 2: Clean up all orphaned DISM mount points system-wide
Write-Host "Step 2: Cleaning up all orphaned DISM mount points..." -ForegroundColor Cyan
& $DismExe /Cleanup-Mountpoints | Out-Null
Write-Host "      Done." -ForegroundColor Green

# Step 3: Remove build folders
Write-Host "Step 3: Removing stale build folders..." -ForegroundColor Cyan
if (Test-Path $MountDir) {
    Remove-Item $MountDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "      Removed: Build\Mount" -ForegroundColor Green
} else {
    Write-Host "      Build\Mount not found - skipping" -ForegroundColor Gray
}

if (Test-Path $StageDir) {
    Remove-Item $StageDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "      Removed: Build\WinPE_x64" -ForegroundColor Green
} else {
    Write-Host "      Build\WinPE_x64 not found - skipping" -ForegroundColor Gray
}

# Step 4: Verify mount dir is truly gone
Write-Host "Step 4: Verifying cleanup..." -ForegroundColor Cyan
$remaining = & $DismExe /Get-MountedWimInfo 2>&1 | Select-String "Mount Dir"
if ($remaining) {
    Write-Host "      WARNING: Some mounts may still be registered:" -ForegroundColor Yellow
    $remaining | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
    Write-Host "      Try rebooting the build machine then running this script again." -ForegroundColor Yellow
} else {
    Write-Host "      No stale mounts detected." -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Repair complete. You can now run .\Build-WinPE.ps1" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
