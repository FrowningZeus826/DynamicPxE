# ============================================================
#  Inject-Drivers.ps1
#  Injects a driver pack into the applied OS image using DISM
#  Supports offline injection to the OS partition in WinPE
# ============================================================

function Invoke-DriverInjection {
    <#
    .SYNOPSIS
        Injects a driver pack directory into an offline Windows installation.
    .PARAMETER DriverPackPath
        Full path to the driver pack folder (local or UNC)
    .PARAMETER TargetDrive
        Drive letter of the applied OS partition (e.g. "W:")
    .PARAMETER ForceUnsigned
        If true, allows injection of unsigned drivers (use with caution)
    .PARAMETER StatusCallback
        ScriptBlock called with status string for GUI updates
    .OUTPUTS
        PSCustomObject with Success, DriversAdded, DriversFailed, ErrorMessage
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriverPackPath,
        [string]$TargetDrive    = "W:",
        [bool]$ForceUnsigned    = $false,
        [scriptblock]$StatusCallback
    )

    Write-LogInfo -Msg "Injecting drivers from: $DriverPackPath -> $TargetDrive" -Comp "DriverInject"

    if (-not (Test-Path $DriverPackPath)) {
        $err = "Driver pack path not found: $DriverPackPath"
        Write-LogError -Msg $err -Comp "DriverInject"
        return [PSCustomObject]@{ Success = $false; DriversAdded = 0; DriversFailed = 0; ErrorMessage = $err }
    }

    # Count INF files for reporting
    $infFiles = Get-ChildItem -Path $DriverPackPath -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue
    Write-LogInfo -Msg "Found $($infFiles.Count) INF file(s) in driver pack" -Comp "DriverInject"

    if ($StatusCallback) { & $StatusCallback "Injecting $($infFiles.Count) drivers..." }

    #  Build DISM arguments 
    $dismArgs = @(
        "/Image:$TargetDrive\",
        "/Add-Driver",
        "/Driver:$DriverPackPath",
        "/Recurse"
    )

    if ($ForceUnsigned) {
        $dismArgs += "/ForceUnsigned"
        Write-LogWarn -Msg "ForceUnsigned enabled - injecting unsigned drivers" -Comp "DriverInject"
    }

    Write-LogDebug -Msg "DISM args: $dismArgs" -Comp "DriverInject"

    $startTime = Get-Date
    $startTime  = Get-Date
    $dismOutput = & dism.exe @dismArgs 2>&1
    $exitCode   = $LASTEXITCODE

    $elapsed = (Get-Date) - $startTime
    $outLog = $dismOutput -join "`n"

    # Parse driver counts from DISM output
    $logText = if ($null -ne $outLog) { $outLog } else { "" }
    $added  = ([regex]::Matches($logText, "The driver package was successfully installed")).Count
    $failed = ([regex]::Matches($logText, "could not be installed|Error")).Count

    Write-LogInfo -Msg "Driver injection done in $($elapsed.ToString('mm\:ss')). Added: $added, Failed: $failed" -Comp "DriverInject"

    if ($exitCode -ne 0 -and $exitCode -ne 50) {
        # Exit 50 = "No drivers found" - not fatal if pack is empty for this arch
        $errMsg = "DISM driver inject failed (exit $($exitCode)): $errLog"
        Write-LogError -Msg $errMsg -Comp "DriverInject"
        return [PSCustomObject]@{
            Success      = $false
            DriversAdded = $added
            DriversFailed = $failed
            ErrorMessage = $errMsg
        }
    }

    if ($StatusCallback) { & $StatusCallback "Driver injection complete ($added drivers added)" }

    return [PSCustomObject]@{
        Success       = $true
        DriversAdded  = $added
        DriversFailed = $failed
        ErrorMessage  = $null
    }
}

function Get-InjectedDrivers {
    <#
    .SYNOPSIS
        Lists drivers currently injected into an offline OS image.
    .PARAMETER TargetDrive
        Drive letter of the offline OS partition.
    #>
    param([string]$TargetDrive = "W:")

    Write-LogInfo -Msg "Enumerating injected drivers on $TargetDrive" -Comp "DriverInject"
    $output = dism /Image:"$TargetDrive\" /Get-Drivers 2>&1

    $drivers = @()
    $current = @{}
    foreach ($line in $output) {
        if ($line -match "^Published Name\s*:\s*(.+)")  { $current.Published = $Matches[1].Trim() }
        if ($line -match "^Original File Name\s*:\s*(.+)") { $current.OrigName = $Matches[1].Trim() }
        if ($line -match "^Provider Name\s*:\s*(.+)")   { $current.Provider = $Matches[1].Trim() }
        if ($line -match "^Class Name\s*:\s*(.+)") {
            $current.Class = $Matches[1].Trim()
            $drivers += [PSCustomObject]$current
            $current = @{}
        }
    }
    return $drivers
}
