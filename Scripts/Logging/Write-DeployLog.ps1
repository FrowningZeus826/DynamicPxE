# ============================================================
#  Write-DeployLog.ps1
#  Structured logging for the WinPE deployment environment
#  Location: \Deploy\Scripts\Logging\Write-DeployLog.ps1
# ============================================================

$script:LogPath  = "X:\Deploy\Logs\deploy.log"
$script:LogLevel = "INFO"   # DEBUG | INFO | WARN | ERROR

# Ensure log directory exists
function Initialize-Log {
    param([string]$Path = $script:LogPath)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogPath = $Path
    Write-DeployLog -Level INFO -Message "=== Dell Deploy Session Started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
}

# Core logging function
function Write-DeployLog {
    param(
        [ValidateSet("DEBUG","INFO","WARN","ERROR")]
        [string]$Level = "INFO",
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Component = "General",
        # Optional ScriptBlock callback to update GUI status label
        [scriptblock]$GuiCallback
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry     = "[$timestamp] [$Level] [$Component] $Message"

    # Write to file
    try {
        Add-Content -Path $script:LogPath -Value $entry -Encoding UTF8
    } catch {
        # If log write fails, write to TEMP as fallback
        Add-Content -Path "$env:TEMP\deploy_fallback.log" -Value $entry -Encoding UTF8
    }

    # Write to console with color
    $color = switch ($Level) {
        "DEBUG" { "Gray"    }
        "INFO"  { "Cyan"    }
        "WARN"  { "Yellow"  }
        "ERROR" { "Red"     }
    }
    Write-Host $entry -ForegroundColor $color

    # Fire GUI callback if provided (used to update status label)
    if ($GuiCallback) {
        try { & $GuiCallback $Message } catch { }
    }
}

# Convenience wrappers
function Write-LogInfo  { param([string]$Msg, [string]$Comp = "General") Write-DeployLog -Level INFO  -Message $Msg -Component $Comp }
function Write-LogWarn  { param([string]$Msg, [string]$Comp = "General") Write-DeployLog -Level WARN  -Message $Msg -Component $Comp }
function Write-LogError { param([string]$Msg, [string]$Comp = "General") Write-DeployLog -Level ERROR -Message $Msg -Component $Comp }
function Write-LogDebug { param([string]$Msg, [string]$Comp = "General") Write-DeployLog -Level DEBUG -Message $Msg -Component $Comp }

# Get full log content as string (for GUI log viewer)
function Get-LogContent {
    if (Test-Path $script:LogPath) {
        return Get-Content -Path $script:LogPath -Raw -Encoding UTF8
    }
    return "(log file not yet created)"
}

# Note: dot-sourced with . operator - all functions available automatically in caller scope
