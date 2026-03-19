# ============================================================
#  Apply-Image.ps1
#  Partitions the target disk and applies a WIM/SWM using DISM
#  Designed for UEFI systems (GPT + EFI + MSR + OS + Recovery)
# ============================================================

function Invoke-DiskPrep {
    <#
    .SYNOPSIS
        Initializes target disk with UEFI-compatible GPT layout.
    .PARAMETER DiskNumber
        Physical disk number (default: 0)
    .OUTPUTS
        PSCustomObject with OSDriveLetter, EFIPartition, Success
    #>
    [CmdletBinding()]
    param(
        [int]$DiskNumber    = 0,
        [string]$OSDrive    = "W"   # Drive letter for OS partition during WinPE
    )

    Write-LogInfo -Msg "Preparing disk $DiskNumber (UEFI/GPT layout)" -Comp "DiskPrep"

    # Build diskpart script
    $dpScript = @"
select disk $DiskNumber
clean
convert gpt

rem -- EFI System Partition (260MB, FAT32)
create partition efi size=260
format quick fs=fat32 label="System"
assign letter=S

rem -- Microsoft Reserved (16MB)
create partition msr size=16

rem -- OS Partition (remaining space minus 650MB for recovery)
create partition primary
shrink minimum=650
format quick fs=ntfs label="Windows"
assign letter=$OSDrive

rem -- Recovery Partition (650MB)
create partition primary
format quick fs=ntfs label="Recovery"
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001

list partition
"@

    $dpFile = "$env:TEMP\diskpart_prep.txt"
    $dpScript | Set-Content -Path $dpFile -Encoding ASCII

    Write-LogDebug -Msg "Running diskpart..." -Comp "DiskPrep"
    $dpOut = diskpart /s $dpFile 2>&1
    Write-LogDebug -Msg $dpOut -Comp "DiskPrep"

    Remove-Item $dpFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-LogError -Msg "diskpart failed with exit code $LASTEXITCODE" -Comp "DiskPrep"
        return [PSCustomObject]@{ Success = $false; OSDriveLetter = $null; EFIPartition = $null }
    }

    Write-LogInfo -Msg "Disk $DiskNumber prepared. OS drive: ${OSDrive}:  EFI drive: S:" -Comp "DiskPrep"
    return [PSCustomObject]@{
        Success       = $true
        OSDriveLetter = "${OSDrive}:"
        EFIPartition  = "S:"
    }
}

function Apply-OSImage {
    <#
    .SYNOPSIS
        Applies a WIM or SWM to the target OS partition using DISM.
    .PARAMETER ImagePath
        Full path to .wim or first .swm file
    .PARAMETER TargetDrive
        Drive letter of the prepared OS partition (e.g. "W:")
    .PARAMETER ImageIndex
        WIM image index to apply (default: 1). Use Get-WimInfo to enumerate.
    .PARAMETER StatusCallback
        ScriptBlock called with progress % - used to update GUI progress bar
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,
        [string]$TargetDrive   = "W:",
        [int]$ImageIndex       = 2,   # Dell Image Assist WIMs: index 2 = Windows_IW (the OS)
        [scriptblock]$StatusCallback
    )

    Write-LogInfo -Msg "Applying image: $ImagePath -> $TargetDrive (Index $ImageIndex)" -Comp "ApplyImage"

    if (-not (Test-Path $ImagePath)) {
        Write-LogError -Msg "Image not found: $ImagePath" -Comp "ApplyImage"
        return $false
    }

    #  Detect SWM (split WIM)
    $isSplit = $ImagePath -match '\.swm$'

    # Build argument list as plain array - no embedded quotes
    # Using & operator handles paths with spaces correctly
    $dismArgs = @(
        "/Apply-Image",
        "/ImageFile:$ImagePath",
        "/Index:$ImageIndex",
        "/ApplyDir:$TargetDrive\"
    )

    if ($isSplit) {
        $swmPattern = $ImagePath -replace '\.swm$','*.swm'
        $dismArgs += "/SWMFile:$swmPattern"
        Write-LogInfo -Msg "Split WIM detected - SWM pattern: $swmPattern" -Comp "ApplyImage"
    }

    #  Run DISM directly with & operator - handles UNC paths and spaces correctly
    Write-LogInfo -Msg "Starting DISM apply (this may take 10-30+ minutes)..." -Comp "ApplyImage"
    Write-LogInfo -Msg "ImageFile: $ImagePath" -Comp "ApplyImage"
    Write-LogInfo -Msg "ApplyDir:  $TargetDrive" -Comp "ApplyImage"

    $startTime  = Get-Date
    $dismOutput = & dism.exe @dismArgs 2>&1
    $exitCode   = $LASTEXITCODE

    # Log all DISM output for diagnostics
    $dismOutput | ForEach-Object { Write-LogInfo -Msg "DISM: $_" -Comp "ApplyImage" }

    # Parse last percentage for progress callback
    # Note: MatchCollection does not support [-1] indexing in PS5.1 - use Count-1
    if ($StatusCallback) {
        $dismText     = if ($null -ne $dismOutput) { $dismOutput -join "`n" } else { "" }
        $percentMatch = [regex]::Matches($dismText, '(\d+\.\d+)%')
        if ($percentMatch.Count -gt 0) {
            $lastPct = [int][double]$percentMatch[$percentMatch.Count - 1].Groups[1].Value
            & $StatusCallback $lastPct
        }
    }

    $elapsed = (Get-Date) - $startTime
    Write-LogInfo -Msg "DISM apply finished in $($elapsed.ToString('mm\:ss')) - exit code: $exitCode" -Comp "ApplyImage"

    if ($exitCode -ne 0) {
        Write-LogError -Msg "DISM apply failed (exit $exitCode)" -Comp "ApplyImage"
        return $false
    }

    Write-LogInfo -Msg "Image applied successfully to $TargetDrive" -Comp "ApplyImage"
    return $true
}

function Set-BootConfig {
    <#
    .SYNOPSIS
        Configures BCD/bootmgr on the EFI partition.
    .PARAMETER OSDrive
        OS partition drive letter (e.g. "W:")
    .PARAMETER EFIDrive
        EFI partition drive letter (e.g. "S:")
    #>
    [CmdletBinding()]
    param(
        [string]$OSDrive  = "W:",
        [string]$EFIDrive = "S:"
    )

    Write-LogInfo -Msg "Configuring boot (BCDboot): $OSDrive -> $EFIDrive" -Comp "BootConfig"

    # Use & operator - handles paths correctly without Start-Process quoting issues
    $bcdOutput = & bcdboot.exe "$OSDrive\Windows" /s $EFIDrive /f UEFI 2>&1
    $bcdExit   = $LASTEXITCODE
    $bcdOutput | ForEach-Object { Write-LogInfo -Msg "BCDboot: $_" -Comp "BootConfig" }

    if ($bcdExit -ne 0) {
        Write-LogError -Msg "BCDboot failed with exit $bcdExit" -Comp "BootConfig"
        return $false
    }

    # Set one-time boot sequence to Windows Boot Manager
    # This ensures the machine boots to the SSD on next reboot without
    # permanently changing the UEFI boot order (PXE remains available after)
    Write-LogInfo -Msg "Setting one-time boot sequence to Windows Boot Manager..." -Comp "BootConfig"
    $bcdeditOutput = & bcdedit.exe /set "{fwbootmgr}" bootsequence "{bootmgr}" 2>&1
    $bcdeditExit   = $LASTEXITCODE
    $bcdeditOutput | ForEach-Object { Write-LogInfo -Msg "BCDEdit: $_" -Comp "BootConfig" }
    if ($bcdeditExit -ne 0) {
        Write-LogWarn -Msg "BCDEdit bootsequence failed (exit $bcdeditExit) - machine may need F12 on first boot" -Comp "BootConfig"
    } else {
        Write-LogInfo -Msg "One-time boot sequence set - machine will boot to Windows on next reboot" -Comp "BootConfig"
    }

    Write-LogInfo -Msg "Boot configuration complete" -Comp "BootConfig"
    return $true
}

function Get-WimImageInfo {
    <#
    .SYNOPSIS
        Enumerates images inside a WIM file.
        Handles Dell Image Assist WIM structure where index 2 (Windows_IW) is the OS.

    Dell Image Assist WIM index layout:
        Index 1  - BLANK1  / System       - Dell IA system partition data (not deployable)
        Index 2  - BLANK2  / Windows_IW   - ACTUAL WINDOWS OS  <-- always deploy this
        Index 3  - BLANK3  / Recovery     - Recovery placeholder (0 bytes)
        Index 4  - BLANK4  / Summary_IA   - Dell IA deployment metadata
        Index 5  - BLANK5  / Logs         - Dell IA capture logs

    .OUTPUTS
        Array of PSCustomObjects with Index, Name, Description, SizeBytes, SizeGB,
        IsDeployable, IsDellIA, DisplayLabel
    #>
    param([Parameter(Mandatory)][string]$WimPath)

    $output = dism /Get-WimInfo /WimFile:"$WimPath" 2>&1
    $images = @()
    $current = @{}

    foreach ($line in $output) {
        if ($line -match "^Index\s*:\s*(\d+)")      { $current.Index       = [int]$Matches[1] }
        if ($line -match "^Name\s*:\s*(.+)")         { $current.Name        = $Matches[1].Trim() }
        if ($line -match "^Description\s*:\s*(.+)")  { $current.Description = $Matches[1].Trim() }
        if ($line -match "^Size\s*:\s*(.+)") {
            $rawSize = $Matches[1].Trim()
            # Parse numeric bytes (remove commas)
            $bytes = 0
            [long]::TryParse(($rawSize -replace '[^0-9]',''), [ref]$bytes) | Out-Null
            $current.SizeBytes = $bytes
            $current.SizeGB    = if ($bytes -gt 0) { [math]::Round($bytes/1GB,2) } else { 0 }
            $images += [PSCustomObject]$current
            $current = @{}
        }
    }

    #  Identify Dell Image Assist WIM structure 
    # Detection: 5 indexes where index 2 description is "Windows_IW"
    $isDellIA = $false
    if ($images.Count -eq 5) {
        $idx2 = $images | Where-Object { $_.Index -eq 2 }
        if ($idx2 -and $idx2.Description -eq "Windows_IW") {
            $isDellIA = $true
        }
    }

    #  Annotate each index 
    foreach ($img in $images) {
        $img | Add-Member -NotePropertyName IsDellIA     -NotePropertyValue $isDellIA
        $img | Add-Member -NotePropertyName IsDeployable -NotePropertyValue $false
        $img | Add-Member -NotePropertyName DisplayLabel -NotePropertyValue ""

        if ($isDellIA) {
            switch ($img.Index) {
                1 { $img.DisplayLabel = "Index 1 -- System (Dell IA metadata, not deployable)" }
                2 { $img.DisplayLabel = "Index 2 -- Windows OS  <- DEPLOY THIS"
                    $img.IsDeployable  = $true }
                3 { $img.DisplayLabel = "Index 3 -- Recovery placeholder (0 bytes)" }
                4 { $img.DisplayLabel = "Index 4 -- Dell IA Summary (metadata only)" }
                5 { $img.DisplayLabel = "Index 5 -- Dell IA Logs (metadata only)" }
            }
        } else {
            # Standard WIM - all non-zero indexes are deployable
            $img.IsDeployable  = ($img.SizeBytes -gt 0)
            $img.DisplayLabel  = "Index $($img.Index) -- $($img.Name)"
            if ($img.Description) { $img.DisplayLabel += " ($($img.Description))" }
            if ($img.SizeGB -gt 0) { $img.DisplayLabel += " [$($img.SizeGB) GB]" }
        }
    }

    return $images
}

# Returns just the correct deployable index for a WIM
# For Dell IA WIMs always returns 2; for standard WIMs returns the first deployable index
function Get-DeployableImageIndex {
    param([Parameter(Mandatory)][string]$WimPath)
    $images = Get-WimImageInfo -WimPath $WimPath
    $deployable = $images | Where-Object { $_.IsDeployable } | Select-Object -First 1
    if ($deployable) { return $deployable.Index }
    return 1  # fallback
}
