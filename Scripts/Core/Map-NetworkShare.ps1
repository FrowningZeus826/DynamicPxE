# ============================================================
#  Map-NetworkShare.ps1
#  Authenticates and maps the network share in WinPE
#  Uses net use with inline credentials (cmdkey not available in WinPE)
# ============================================================

# Share path loaded from DeployConfig.json by the GUI at startup
# These defaults are used if called outside the GUI context
# ShareRoot and DriveLetter are set by the GUI from DeployConfig.json
$script:DriveLetter = "Z:"
$script:ImagesPath  = "Z:\Images"
$script:DriversPath = "Z:\Drivers"

function Connect-NetworkShare {
    <#
    .SYNOPSIS
        Maps the deployment share using provided credentials.
    .PARAMETER SharePath
        UNC path to map. Defaults to \\your-server\your-share
    .PARAMETER Username
        Domain\Username or just Username for local accounts
    .PARAMETER Password
        SecureString password
    .PARAMETER DriveLetter
        Drive letter to map to (e.g. "Z:")
    .OUTPUTS
        PSCustomObject with Success, SharePath, DriveLetter, ErrorMessage
    #>
    [CmdletBinding()]
    param(
        [string]$SharePath    = $script:ShareRoot,
        [Parameter(Mandatory)]
        [string]$Username,
        [Parameter(Mandatory)]
        [System.Security.SecureString]$Password,
        [string]$DriveLetter  = $script:DriveLetter
    )

    Write-LogInfo -Msg "Connecting to $SharePath as $Username" -Comp "Network"

    # Convert SecureString to plain text for net use
    # cmdkey.exe is not available in WinPE - pass credentials directly to net use
    $bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    try {
        # Remove existing drive mapping if present
        if (Test-Path $DriveLetter) {
            Write-LogDebug -Msg "Removing existing mapping on $DriveLetter" -Comp "Network"
            net use $DriveLetter /delete /y 2>$null | Out-Null
        }

        # Map the drive passing credentials directly to net use
        # This works in WinPE without cmdkey.exe
        $output = net use $DriveLetter $SharePath $plainPass /user:$Username /persistent:no /y 2>&1

        if ($LASTEXITCODE -eq 0 -or (Test-Path $DriveLetter)) {
            Write-LogInfo -Msg "Share mapped successfully: $DriveLetter -> $SharePath" -Comp "Network"
            return [PSCustomObject]@{
                Success      = $true
                SharePath    = $SharePath
                DriveLetter  = $DriveLetter
                ImagesPath   = "$DriveLetter\Images"
                DriversPath  = "$DriveLetter\Drivers"
                ErrorMessage = $null
            }
        } else {
            $errMsg = "net use failed (exit $LASTEXITCODE): $output"
            Write-LogError -Msg $errMsg -Comp "Network"
            return [PSCustomObject]@{
                Success      = $false
                SharePath    = $SharePath
                DriveLetter  = $null
                ImagesPath   = $null
                DriversPath  = $null
                ErrorMessage = $errMsg
            }
        }
    }
    catch {
        Write-LogError -Msg "Share connection exception: $_" -Comp "Network"
        return [PSCustomObject]@{
            Success      = $false
            SharePath    = $SharePath
            DriveLetter  = $null
            ImagesPath   = $null
            DriversPath  = $null
            ErrorMessage = $_.Exception.Message
        }
    }
    finally {
        # Always zero out plaintext password variable
        $plainPass = $null
    }
}

function Disconnect-NetworkShare {
    param([string]$DriveLetter = $script:DriveLetter)
    Write-LogInfo -Msg "Disconnecting share $DriveLetter" -Comp "Network"
    net use $DriveLetter /delete /y 2>$null | Out-Null
}

function Test-ShareConnectivity {
    <#
    .SYNOPSIS
        Tests if the deployment share is accessible (after mapping).
    #>
    param([string]$DriveLetter = $script:DriveLetter)
    $imagesOk  = Test-Path "$DriveLetter\Images"
    $driversOk = Test-Path "$DriveLetter\Drivers"
    Write-LogInfo -Msg "Share health: Images=$imagesOk, Drivers=$driversOk" -Comp "Network"
    return $imagesOk -and $driversOk
}

# Returns all WIM/SWM files from the Images folder
function Get-AvailableImages {
    param([string]$ImagesPath = "$($script:DriveLetter)\Images")
    if (-not (Test-Path $ImagesPath)) {
        Write-LogWarn -Msg "Images path not accessible: $ImagesPath" -Comp "Network"
        return @()
    }
    $images = Get-ChildItem -Path $ImagesPath -Include "*.wim","*.swm" -Recurse -ErrorAction SilentlyContinue
    Write-LogInfo -Msg "Found $($images.Count) image(s) in $ImagesPath" -Comp "Network"
    return $images | Select-Object Name, FullName,
        @{N="SizeGB"; E={[math]::Round($_.Length/1GB,2)}},
        LastWriteTime
}

# Returns all ZIP driver packs (sorted by name; higher 'a' revision last within same model)
function Get-AvailableDriverPacks {
    param([string]$DriversPath = "$($script:DriveLetter)\Drivers")
    if (-not (Test-Path $DriversPath)) {
        Write-LogWarn -Msg "Drivers path not accessible: $DriversPath" -Comp "Network"
        return @()
    }
    $zips = Get-ChildItem -Path $DriversPath -Filter "*.zip" -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {
                [PSCustomObject]@{
                    Name        = $_.Name
                    FullName    = $_.FullName
                    IsZip       = $true
                    SizeMB      = [math]::Round($_.Length / 1MB, 1)
                    DisplayName = "$($_.BaseName)  [$([math]::Round($_.Length/1MB,1)) MB]"
                }
            } | Where-Object { $_ }
    Write-LogInfo -Msg "Found $(@($zips).Count) ZIP driver pack(s) in $DriversPath" -Comp "Network"
    return $zips
}
