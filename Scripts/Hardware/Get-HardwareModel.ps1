# ============================================================
#  Get-HardwareModel.ps1
#  Detects hardware model via WMI — multi-vendor
#  Supports Dell, Lenovo, HP, and generic fallback
#  Returns a structured object with model details
# ============================================================

function Get-HardwareInfo {
    <#
    .SYNOPSIS
        Detects hardware model information via WMI/CIM.
        Supports Dell, Lenovo, HP, and generic hardware.
    .OUTPUTS
        PSCustomObject with Manufacturer, Model, SystemFamily, ServiceTag,
        BIOSVersion, Vendor, ModelKey
    #>
    [CmdletBinding()]
    param()

    try {
        $cs   = Get-CimInstance -ClassName Win32_ComputerSystem   -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS              -ErrorAction Stop

        $mfr = $cs.Manufacturer.Trim()

        # Normalize vendor name
        $vendor = switch -Regex ($mfr) {
            "Dell"    { "Dell"   }
            "Lenovo"  { "Lenovo" }
            "HP|Hewlett" { "HP"  }
            "Microsoft" { "Microsoft" }
            default   { "Generic" }
        }

        # Build SystemFamily safely — PS 5.1 cannot use if-expressions inline in @{}
        $sysFamily = "Unknown"
        if ($null -ne $cs.SystemFamily -and $cs.SystemFamily.Trim() -ne "") {
            $sysFamily = $cs.SystemFamily.Trim()
        }

        # Lenovo uses Version field for real model name on some systems
        # e.g. Win32_ComputerSystem.Model may be "30FW" (machine type)
        # while BIOS.Description or cs.SystemFamily holds "ThinkPad X1 Carbon Gen 9"
        $modelDisplay = $cs.Model.Trim()
        if ($vendor -eq "Lenovo" -and $sysFamily -ne "Unknown" -and
            $cs.Model -match '^\w{4,6}$') {
            # Model looks like a bare machine type code (e.g. "30FW") — use family instead
            $modelDisplay = $sysFamily
        }

        $result = [PSCustomObject]@{
            Manufacturer  = $mfr
            Model         = $modelDisplay
            ModelRaw      = $cs.Model.Trim()      # Always the raw WMI model field
            SystemFamily  = $sysFamily
            ServiceTag    = $bios.SerialNumber.Trim()
            BIOSVersion   = $bios.SMBIOSBIOSVersion.Trim()
            Vendor        = $vendor
            ModelKey      = ($modelDisplay -replace '\s+','-').ToLower()
        }

        Write-LogInfo -Msg "Detected: $($result.Manufacturer) $($result.Model) [S/N: $($result.ServiceTag)]" -Comp "HWDetect"
        return $result
    }
    catch {
        Write-LogError -Msg "WMI query failed: $_" -Comp "HWDetect"
        return [PSCustomObject]@{
            Manufacturer = "Unknown"
            Model        = "Unknown"
            ModelRaw     = "Unknown"
            SystemFamily = "Unknown"
            ServiceTag   = "Unknown"
            BIOSVersion  = "Unknown"
            Vendor       = "Generic"
            ModelKey     = "unknown"
        }
    }
}

# Convenience wrapper — returns a display string
function Get-HardwareModelString {
    $info = Get-HardwareInfo
    return "$($info.Manufacturer) $($info.Model)"
}
