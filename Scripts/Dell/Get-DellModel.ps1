# ============================================================
#  Get-DellModel.ps1
#  Detects Dell hardware model via WMI
#  Returns a structured object with model details
# ============================================================

function Get-DellModel {
    <#
    .SYNOPSIS
        Detects Dell hardware model information via WMI/CIM.
    .OUTPUTS
        PSCustomObject with Manufacturer, Model, SystemFamily, ServiceTag, BIOS
    #>
    [CmdletBinding()]
    param()

    try {
        $cs   = Get-CimInstance -ClassName Win32_ComputerSystem   -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS              -ErrorAction Stop

        # Build SystemFamily safely before hashtable - PS5.1 cannot use if expressions inline in @{}
        $sysFamily = "Unknown"
        if ($null -ne $cs.SystemFamily -and $cs.SystemFamily -ne "") {
            $sysFamily = $cs.SystemFamily.Trim()
        }

        $result = [PSCustomObject]@{
            Manufacturer  = $cs.Manufacturer.Trim()
            Model         = $cs.Model.Trim()
            SystemFamily  = $sysFamily
            ServiceTag    = $bios.SerialNumber.Trim()
            BIOSVersion   = $bios.SMBIOSBIOSVersion.Trim()
            IsDell        = $cs.Manufacturer -match "Dell"
            ModelKey      = ($cs.Model.Trim() -replace '\s+','-').ToLower()
        }

        Write-LogInfo -Msg "Detected: $($result.Manufacturer) $($result.Model) [S/N: $($result.ServiceTag)]" -Comp "DellDetect"
        return $result
    }
    catch {
        Write-LogError -Msg "WMI query failed: $_" -Comp "DellDetect"
        # Return a safe fallback object
        return [PSCustomObject]@{
            Manufacturer = "Unknown"
            Model        = "Unknown"
            SystemFamily = "Unknown"
            ServiceTag   = "Unknown"
            BIOSVersion  = "Unknown"
            IsDell       = $false
            ModelKey     = "unknown"
        }
    }
}

# Returns just the model string - convenience wrapper for display
function Get-DellModelString {
    $info = Get-DellModel
    if ($info.IsDell) { return "$($info.Model)" }
    return "Non-Dell hardware detected: $($info.Manufacturer) $($info.Model)"
}
