# ============================================================
#  Expand-DriverPack.ps1
#  Extracts a zipped Dell driver pack to a local WinPE temp
#  directory before offline DISM injection.
#
#  Dell ZIP naming convention handled:
#    win10_latitudee10_a23.zip
#    win11_optiplex7010_a05.zip
#    win11_precision3580_a12.zip
#    etc.
#
#  Extraction target: W:\DriverTemp\<basename>\ (OS disk - avoids WinPE RAM disk space limits)
#  This folder is cleaned up after injection to free disk space.
# ============================================================

# Extract to OS disk (W:) not RAM disk (X:) - driver ZIPs can be 1-2GB and exceed WinPE RAM disk space
$script:DriverTempRoot = "W:\DriverTemp"

function Expand-DriverPack {
    <#
    .SYNOPSIS
        Extracts a Dell driver ZIP to the local WinPE temp path.
    .PARAMETER ZipPath
        Full path to the .zip file (local or UNC after share is mapped)
    .PARAMETER ExtractRoot
        Root folder for extractions. Defaults to X:\Deploy\DriverTemp
    .PARAMETER Force
        Re-extract even if a previous extraction exists
    .PARAMETER StatusCallback
        ScriptBlock([string] $status) for GUI updates
    .OUTPUTS
        PSCustomObject: Success, ExtractPath, ZipName, SizeMB, ErrorMessage
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,
        [string]$ExtractRoot    = $script:DriverTempRoot,
        [bool]$Force            = $false,
        [scriptblock]$StatusCallback
    )

    if (-not (Test-Path $ZipPath)) {
        $err = "ZIP not found: $ZipPath"
        Write-LogError -Msg $err -Comp "ExpandZip"
        return [PSCustomObject]@{ Success = $false; ExtractPath = $null; ErrorMessage = $err }
    }

    $zipName    = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $extractTo  = Join-Path $ExtractRoot $zipName
    $zipSizeMB  = [math]::Round((Get-Item $ZipPath).Length / 1MB, 1)

    Write-LogInfo -Msg "Driver ZIP: $([System.IO.Path]::GetFileName($ZipPath)) ($zipSizeMB MB)" -Comp "ExpandZip"

    #  Check for existing extraction 
    if ((Test-Path $extractTo) -and -not $Force) {
        $infCount = (Get-ChildItem $extractTo -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue).Count
        if ($infCount -gt 0) {
            Write-LogInfo -Msg "Reusing existing extraction ($infCount INFs): $extractTo" -Comp "ExpandZip"
            if ($StatusCallback) { & $StatusCallback "Using cached extraction ($infCount drivers)" }
            return [PSCustomObject]@{
                Success      = $true
                ExtractPath  = $extractTo
                ZipName      = $zipName
                SizeMB       = $zipSizeMB
                ErrorMessage = $null
                WasCached    = $true
            }
        }
        # Stale/empty folder -- clean and re-extract
        Write-LogWarn -Msg "Stale extraction found (0 INFs) -- cleaning and re-extracting" -Comp "ExpandZip"
        Remove-Item $extractTo -Recurse -Force -ErrorAction SilentlyContinue
    }

    #  Ensure temp root exists 
    if (-not (Test-Path $ExtractRoot)) {
        New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $extractTo -Force | Out-Null

    Write-LogInfo -Msg "Extracting to: $extractTo" -Comp "ExpandZip"
    if ($StatusCallback) { & $StatusCallback "Extracting $([System.IO.Path]::GetFileName($ZipPath)) ($zipSizeMB MB)..." }

    $startTime = Get-Date

    try {
        #  Use .NET ZipFile (fastest, no external tools needed) 
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $extractTo)

        $elapsed  = (Get-Date) - $startTime
        $infCount = (Get-ChildItem $extractTo -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue).Count

        Write-LogInfo -Msg "Extracted in $($elapsed.ToString('mm\:ss')). INF files found: $infCount" -Comp "ExpandZip"

        if ($infCount -eq 0) {
            Write-LogWarn -Msg "No INF files found after extraction -- ZIP may be empty or wrongly structured" -Comp "ExpandZip"
        }

        if ($StatusCallback) { & $StatusCallback "Extracted $infCount driver INFs in $($elapsed.ToString('mm\:ss'))" }

        return [PSCustomObject]@{
            Success      = $true
            ExtractPath  = $extractTo
            ZipName      = $zipName
            SizeMB       = $zipSizeMB
            InfCount     = $infCount
            ErrorMessage = $null
            WasCached    = $false
        }
    }
    catch {
        #  Fallback: use Expand-Archive (slower but always available) 
        Write-LogWarn -Msg ".NET ZipFile failed ($($_.Exception.Message)) -- falling back to Expand-Archive" -Comp "ExpandZip"
        try {
            Expand-Archive -Path $ZipPath -DestinationPath $extractTo -Force
            $infCount = (Get-ChildItem $extractTo -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue).Count
            $elapsed  = (Get-Date) - $startTime
            Write-LogInfo -Msg "Fallback extraction done in $($elapsed.ToString('mm\:ss')). INFs: $infCount" -Comp "ExpandZip"
            return [PSCustomObject]@{
                Success      = $true
                ExtractPath  = $extractTo
                ZipName      = $zipName
                SizeMB       = $zipSizeMB
                InfCount     = $infCount
                ErrorMessage = $null
                WasCached    = $false
            }
        }
        catch {
            $err = "All extraction methods failed: $($_.Exception.Message)"
            Write-LogError -Msg $err -Comp "ExpandZip"
            return [PSCustomObject]@{
                Success      = $false
                ExtractPath  = $null
                ZipName      = $zipName
                SizeMB       = $zipSizeMB
                InfCount     = 0
                WasCached    = $false
                ErrorMessage = $err
            }
        }
    }
}

function Clear-DriverTemp {
    <#
    .SYNOPSIS
        Removes all extracted driver packs from the WinPE temp folder.
        Call this after deployment completes to free RAM-disk space.
    #>
    param([string]$ExtractRoot = $script:DriverTempRoot)
    if (Test-Path $ExtractRoot) {
        Write-LogInfo -Msg "Clearing driver temp: $ExtractRoot" -Comp "ExpandZip"
        Remove-Item $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-DriverPackInfo {
    <#
    .SYNOPSIS
        Parses a Dell driver ZIP filename into structured metadata.
        Handles the Dell convention: win10_latitudee10_a23.zip
    .OUTPUTS
        PSCustomObject: OSHint, ModelHint, Version, FullName, SizeMB, IsZip
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $FileItem   # FileInfo object or string path
    )
    process {
        if ($FileItem -is [string]) { $FileItem = Get-Item $FileItem -ErrorAction SilentlyContinue }
        if (-not $FileItem)         { return $null }

        $name    = $FileItem.Name
        $base    = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $isZip   = $name -match '\.zip$'
        $sizeMB  = [math]::Round($FileItem.Length / 1MB, 1)

        # Parse Dell naming: {os}_{model}_{version}
        # Examples: win10_latitudee10_a23   win11_optiplex7010_a05
        $osHint    = "Unknown"
        $modelHint = $base
        $version   = ""

        if ($base -match '^(win\d+)_(.+?)_(a\d+)$') {
            $osHint    = $Matches[1]   # e.g. "win10", "win11"
            $modelHint = $Matches[2]   # e.g. "latitudee10", "optiplex7010"
            $version   = $Matches[3]   # e.g. "a23"
        } elseif ($base -match '^(win\d+)_(.+)$') {
            $osHint    = $Matches[1]
            $modelHint = $Matches[2]
        }

        return [PSCustomObject]@{
            FileName   = $name
            BaseName   = $base
            OSHint     = $osHint
            ModelHint  = $modelHint      # raw from filename
            Version    = $version
            SizeMB     = $sizeMB
            IsZip      = $isZip
            FullPath   = $FileItem.FullName
            DisplayName = "$base  [$sizeMB MB]"
        }
    }
}
