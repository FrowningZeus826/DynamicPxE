# ============================================================
#  Invoke-Deployment.ps1
#  Orchestrates the full deployment pipeline:
#    1. Disk preparation
#    2. Image application
#    3. Driver injection
#    4. Boot configuration
#    5. Reboot
#
#  Called by the GUI after user confirms selections.
# ============================================================

#  Import dependencies 
$ScriptRoot = "X:\Deploy\Scripts"
. "$ScriptRoot\Logging\Write-DeployLog.ps1"
. "$ScriptRoot\Core\Apply-Image.ps1"
. "$ScriptRoot\Core\Inject-Drivers.ps1"
. "$ScriptRoot\Core\Expand-DriverPack.ps1"
. "$ScriptRoot\Dell\Get-DellModel.ps1"

# FUTURE: Lenovo
# . "$ScriptRoot\Lenovo\Get-LenovoModel.ps1"

function Invoke-Deployment {
    <#
    .SYNOPSIS
        Runs the full WinPE deployment pipeline.
    .PARAMETER ImagePath
        Full path to the WIM/SWM file to apply
    .PARAMETER DriverPackPath
        Full path to the driver pack ZIP or pre-extracted folder
    .PARAMETER DriverPackIsZip
        Set to $true if DriverPackPath is a .zip file (auto-detected if omitted)
    .PARAMETER ImageIndex
        WIM index to apply (default: 1)
    .PARAMETER TargetDisk
        Physical disk number (default: 0)
    .PARAMETER ProgressCallback
        ScriptBlock(int $percent, string $status) - updates GUI progress
    .PARAMETER ConfirmWipe
        Safety gate - must be $true to proceed with disk wipe
    .OUTPUTS
        PSCustomObject with Success, ErrorMessage, ElapsedTime
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,
        [Parameter(Mandatory)]
        [string]$DriverPackPath,
        [int]$ImageIndex        = 2,   # Dell Image Assist WIMs always use index 2 (Windows_IW)
        [int]$TargetDisk        = 0,
        [object]$DriverPackIsZip = $null,   # auto-detect if not specified
        [scriptblock]$ProgressCallback,
        [bool]$ConfirmWipe      = $false
    )

    $startTime = Get-Date
    Initialize-Log

    function Update-Progress {
        param([int]$Pct, [string]$Status)
        Write-LogInfo -Msg "[$Pct%] $Status" -Comp "Deploy"
        if ($ProgressCallback) { & $ProgressCallback $Pct $Status }
    }

    #  Safety check 
    if (-not $ConfirmWipe) {
        $err = "SAFETY: ConfirmWipe not set. Disk wipe aborted."
        Write-LogError -Msg $err -Comp "Deploy"
        return [PSCustomObject]@{ Success = $false; ErrorMessage = $err; ElapsedTime = $null }
    }

    try {
        #  Step 1: Validate inputs 
        Update-Progress 2 "Validating deployment parameters..."

        if (-not (Test-Path $ImagePath)) {
            throw "Image not found: $ImagePath"
        }
        if (-not (Test-Path $DriverPackPath)) {
            Write-LogWarn -Msg "Driver pack path not found: $DriverPackPath - continuing without drivers" -Comp "Deploy"
        }

        #  Step 2: Detect hardware 
        Update-Progress 5 "Detecting hardware..."
        try { $modelInfo = Get-DellModel } catch { $modelInfo = $null }
        if ($null -eq $modelInfo) {
            $modelInfo = [PSCustomObject]@{
                Manufacturer="Unknown"; Model="Unknown"; ServiceTag="Unknown"
                BIOSVersion="Unknown"; IsDell=$false; ModelKey="unknown"
            }
        }

        # FUTURE: Lenovo branch
        # if (-not $modelInfo.IsDell) {
        #     $modelInfo = Get-LenovoModel
        # }

        Write-LogInfo -Msg "Hardware: $($modelInfo.Manufacturer) $($modelInfo.Model) [$($modelInfo.ServiceTag)]" -Comp "Deploy"

        #  Step 3: Partition disk 
        Update-Progress 10 "Partitioning disk $TargetDisk..."
        $diskResult = Invoke-DiskPrep -DiskNumber $TargetDisk -OSDrive "W"

        if (-not $diskResult.Success) {
            throw "Disk preparation failed. Check logs."
        }

        $osDrive  = $diskResult.OSDriveLetter   # "W:"
        $efiDrive = $diskResult.EFIPartition     # "S:"

        #  Step 4: Apply OS image 
        Update-Progress 15 "Applying OS image (this may take 15-30 minutes)..."

        $imgCallback = {
            param([int]$pct)
            # Map DISM 0-100% to our 15-75% range
            $mapped = 15 + [int]($pct * 0.60)
            Update-Progress $mapped "Applying image... ($pct%)"
        }

        $applyResult = Apply-OSImage -ImagePath $ImagePath `
            -TargetDrive $osDrive `
            -ImageIndex $ImageIndex `
            -StatusCallback $imgCallback

        if (-not $applyResult) {
            throw "OS image application failed. Check DISM logs."
        }

        #  Step 5: Extract ZIP driver pack (if needed) 
        Update-Progress 76 "Preparing driver pack..."

        $driverInjectPath = $DriverPackPath
        if ($DriverPackPath -and (Test-Path $DriverPackPath)) {
            $isZip = if ($null -ne $DriverPackIsZip) { [bool]$DriverPackIsZip } else { $DriverPackPath -match '\.zip$' }

            if ($isZip) {
                Write-LogInfo -Msg "Driver pack is a ZIP - extracting before injection..." -Comp "Deploy"
                Update-Progress 77 "Extracting driver ZIP (this may take a few minutes)..."
                $extractCallback = { param([string]$s) Update-Progress 78 $s }
                $extractResult = Expand-DriverPack -ZipPath $DriverPackPath -StatusCallback $extractCallback

                if ($extractResult.Success) {
                    $driverInjectPath = $extractResult.ExtractPath
                    $cached = if ($extractResult.WasCached) { " (cached)" } else { "" }
                    Write-LogInfo -Msg "Extracted${cached}: $driverInjectPath ($($extractResult.InfCount) INFs)" -Comp "Deploy"
                    Update-Progress 79 "Extraction complete - $($extractResult.InfCount) driver INFs ready"
                } else {
                    Write-LogWarn -Msg "ZIP extraction failed: $($extractResult.ErrorMessage). Skipping drivers." -Comp "Deploy"
                    $driverInjectPath = $null
                }
            }
        } else {
            Write-LogWarn -Msg "Driver pack path not available: $DriverPackPath" -Comp "Deploy"
            $driverInjectPath = $null
        }

        #  Step 5b: Inject drivers 
        Update-Progress 80 "Injecting drivers into OS image..."

        if ($driverInjectPath -and (Test-Path $driverInjectPath)) {
            $drvCallback = { param([string]$s) Update-Progress 83 $s }
            $drvResult = Invoke-DriverInjection -DriverPackPath $driverInjectPath `
                -TargetDrive $osDrive -StatusCallback $drvCallback

            if (-not $drvResult.Success) {
                Write-LogWarn -Msg "Driver injection reported errors (non-fatal). Continuing..." -Comp "Deploy"
            }
            Write-LogInfo -Msg "Cleaning driver temp to free RAM disk space..." -Comp "Deploy"
            Clear-DriverTemp
        } else {
            Write-LogWarn -Msg "Driver pack skipped (no valid path)" -Comp "Deploy"
        }

        #  Step 6: Configure boot 
        Update-Progress 90 "Configuring boot loader..."
        $bootResult = Set-BootConfig -OSDrive $osDrive -EFIDrive $efiDrive

        if (-not $bootResult) {
            throw "Boot configuration failed."
        }

        #  Step 7: Write deployment info 
        Update-Progress 95 "Writing deployment record..."
        $deployInfo = @{
            DeployDate    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Model         = if ($null -ne $modelInfo) { $modelInfo.Model } else { "Unknown" }
            ServiceTag    = if ($null -ne $modelInfo) { $modelInfo.ServiceTag } else { "Unknown" }
            ImageApplied  = (Split-Path $ImagePath -Leaf)
            DriverPack    = if ($DriverPackPath) { (Split-Path $DriverPackPath -Leaf) } else { "None" }
            ImageIndex    = $ImageIndex
        }
        $deployInfo | ConvertTo-Json | Set-Content -Path "$osDrive\Deploy_Info.json" -Encoding UTF8

        $elapsed = (Get-Date) - $startTime
        Update-Progress 100 "Deployment complete! ($($elapsed.ToString('mm\:ss')))"

        Write-LogInfo -Msg "=== DEPLOYMENT SUCCESSFUL in $($elapsed.ToString('mm\:ss')) ===" -Comp "Deploy"

        return [PSCustomObject]@{
            Success      = $true
            ErrorMessage = $null
            ElapsedTime  = $elapsed
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-LogError -Msg "DEPLOYMENT FAILED: $errMsg" -Comp "Deploy"
        if ($ProgressCallback) { & $ProgressCallback -1 "FAILED: $errMsg" }
        return [PSCustomObject]@{
            Success      = $false
            ErrorMessage = $errMsg
            ElapsedTime  = (Get-Date) - $startTime
        }
    }
}
