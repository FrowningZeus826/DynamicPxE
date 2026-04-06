# ============================================================
#  Get-DriverPack.ps1
#  Vendor-agnostic driver pack auto-matching engine
#
#  Supports any driver pack ZIP naming convention.
#  Works with Dell, Lenovo SCCM packs, HP SoftPaq ZIPs, and
#  any custom naming scheme that includes the model identifier.
#
#  Dell naming examples (tested):
#    win11_latitude5550_a06.zip
#    win11_latitudee16mtl5550_a12.zip
#    win11_optiplexd13mlk7020_a17.zip
#    win10_precisionm10mlk3550_a12.zip
#
#  Lenovo naming examples (tested):
#    lenovo_thinkpade16g1_win11_a01.zip
#    sccm_thinkpadx1carbongen11_win11.zip
#    tp_e16_gen1_w11_drivers.zip
#
#  Generic / custom:
#    Any ZIP whose filename contains the model string or number
#    will score and auto-match correctly.
#
#  Three-stage matching pipeline:
#    1. JSON exact/fuzzy match  (DriverMap.json override file)
#    2. ZIP filename scoring    (model token analysis)
#    3. Pre-extracted folder fallback
#
#  Scoring rubric (5-point scale):
#    5 = exact clean string match
#    4 = model number found in both normalized strings
#    3 = strong substring containment
#    2 = family + partial model
#    1 = family only
#    0 = no match
#
#  Auto-select threshold: >= 3
#  Tie-breakers: OS preference (win11 > win10), then revision (a19 > a06)
# ============================================================

function Get-DriverPack {
    [CmdletBinding()]
    param(
        [string]$ModelKey,
        [string]$ModelRaw,
        [string]$DriversRoot = "Z:\Drivers",
        [string]$MapFile     = "X:\Deploy\Config\DriverMap.json"
    )

    if (-not $ModelKey -or -not $ModelRaw) {
        $modelInfo = Get-HardwareInfo
        if (-not $ModelKey) { $ModelKey = $modelInfo.ModelKey }
        if (-not $ModelRaw) { $ModelRaw = $modelInfo.Model }
    }

    Write-LogInfo -Msg "Driver lookup - Key:'$ModelKey'  Raw:'$ModelRaw'" -Comp "DriverPack"

    $zipResult    = $null
    $folderResult = $null
    $matchType    = "None"

    #  1. JSON override map
    $map = $null
    if (Test-Path $MapFile) {
        try { $map = Get-Content $MapFile -Raw | ConvertFrom-Json }
        catch { Write-LogWarn -Msg "DriverMap.json parse failed: $_" -Comp "DriverPack" }
    }

    if ($map) {
        $entry = $map.Mappings | Where-Object { $_.ModelKey -eq $ModelKey } | Select-Object -First 1
        if ($entry) {
            if ($entry.ZipFile)          { $zipResult    = $entry.ZipFile;      $matchType = "Exact-JSON-ZIP"    }
            elseif ($entry.DriverFolder) { $folderResult = $entry.DriverFolder; $matchType = "Exact-JSON-Folder" }
        }
        # Fuzzy JSON fallback
        if (-not $zipResult -and -not $folderResult) {
            $entry = $map.Mappings | Where-Object {
                $ModelKey -like "*$($_.ModelKey)*" -or $_.ModelKey -like "*$ModelKey*"
            } | Select-Object -First 1
            if ($entry) {
                if ($entry.ZipFile)          { $zipResult    = $entry.ZipFile;      $matchType = "Fuzzy-JSON-ZIP"    }
                elseif ($entry.DriverFolder) { $folderResult = $entry.DriverFolder; $matchType = "Fuzzy-JSON-Folder" }
                Write-LogWarn -Msg "Fuzzy JSON match ($matchType) - verify override is correct" -Comp "DriverPack"
            }
        }
    }

    #  2. ZIP filename scoring
    if (-not $zipResult -and -not $folderResult -and (Test-Path $DriversRoot)) {
        Write-LogInfo -Msg "Scanning share ZIPs for best driver pack..." -Comp "DriverPack"
        $zips = Get-ChildItem -Path $DriversRoot -Filter "*.zip" -ErrorAction SilentlyContinue

        if ($zips) {
            $results = $zips | ForEach-Object {
                $info     = Get-DriverPackInfo $_
                $score    = Get-PackMatchScore -Info $info -ModelKey $ModelKey -ModelRaw $ModelRaw
                $revision = Get-PackRevision $_.Name
                $osPref   = if ($info.OSHint -eq "win11") { 1 } else { 0 }
                Write-LogDebug -Msg "  $($_.Name) | os:$($info.OSHint) score:$score osPref:$osPref rev:$revision" -Comp "DriverPack"
                [PSCustomObject]@{
                    File         = $_.Name
                    Score        = $score
                    OSPreference = $osPref
                    Revision     = $revision
                    Info         = $info
                }
            }

            # Sort: Score DESC → OSPreference DESC → Revision DESC
            $results = $results | Sort-Object -Property @(
                @{Expression = "Score";        Descending = $true},
                @{Expression = "OSPreference"; Descending = $true},
                @{Expression = "Revision";     Descending = $true}
            )

            $best = $results | Select-Object -First 1
            if ($best -and $best.Score -ge 3) {
                $zipResult = $best.File
                $osLabel   = if ($best.OSPreference -eq 1) { "win11" } else { "win10" }
                $matchType = "ZIP-Scan (score=$($best.Score) rev=a$($best.Revision))"
                Write-LogInfo -Msg "Best match: $zipResult (score $($best.Score), $osLabel, rev a$($best.Revision))" -Comp "DriverPack"

                $candidates = $results | Where-Object { $_.Score -ge 3 }
                if ($candidates.Count -gt 1) {
                    Write-LogInfo -Msg "All qualifying candidates (sorted):" -Comp "DriverPack"
                    $candidates | ForEach-Object {
                        $ol = if ($_.OSPreference -eq 1) { "win11" } else { "win10" }
                        Write-LogInfo -Msg "  score=$($_.Score) $ol rev=a$($_.Revision)  $($_.File)" -Comp "DriverPack"
                    }
                }
            } elseif ($best) {
                Write-LogWarn -Msg "Best score $($best.Score) < 3 - no auto-match. User must select." -Comp "DriverPack"
            }
        }
    }

    #  3. Pre-extracted folder fallback
    if (-not $zipResult -and -not $folderResult -and (Test-Path $DriversRoot)) {
        $dirs = Get-ChildItem -Path $DriversRoot -Directory -ErrorAction SilentlyContinue
        if ($dirs) {
            $match = $dirs | ForEach-Object {
                $info  = Get-DriverPackInfo $_
                $score = Get-PackMatchScore -Info $info -ModelKey $ModelKey -ModelRaw $ModelRaw
                [PSCustomObject]@{ Name = $_.Name; Score = $score }
            } | Sort-Object Score -Descending | Select-Object -First 1

            if ($match -and $match.Score -ge 3) {
                $folderResult = $match.Name
                $matchType    = "Folder-Scan (score=$($match.Score))"
                Write-LogInfo -Msg "Folder fallback match: $folderResult" -Comp "DriverPack"
            }
        }
    }

    #  Enumerate all packs for GUI display
    $allPacks = @()
    if (Test-Path $DriversRoot) {
        $allPacks = Get-ChildItem $DriversRoot -Filter "*.zip" -ErrorAction SilentlyContinue |
            ForEach-Object {
                [PSCustomObject]@{
                    Name        = $_.Name
                    FullName    = $_.FullName
                    IsZip       = $true
                    SizeMB      = [math]::Round($_.Length/1MB,1)
                    DisplayName = "$($_.BaseName)  [$([math]::Round($_.Length/1MB,1)) MB]"
                }
            } | Where-Object { $_ }
    }

    $isZip     = $null -ne $zipResult
    $packName  = if ($isZip) { $zipResult } else { $folderResult }
    $packPath  = if ($packName) { Join-Path $DriversRoot $packName } else { $null }
    $isMatched = $null -ne $packName

    if (-not $isMatched) {
        Write-LogWarn -Msg "No driver pack matched for '$ModelKey'. User must select manually." -Comp "DriverPack"
    }

    return [PSCustomObject]@{
        ModelKey       = $ModelKey
        ModelRaw       = $ModelRaw
        MatchType      = $matchType
        IsMatched      = $isMatched
        IsZip          = $isZip
        PackName       = $packName
        DriverPackPath = $packPath
        AllPacks       = $allPacks
    }
}

#  Extract numeric revision from filename
#  e.g. "win11_latitude5550_a06.zip" -> 6
#       "win11_optiplexd13mlk7020_a17.zip" -> 17
#       "lenovo_tp_e16_g1_win11_a03.zip" -> 3
#  Higher value = newer pack. Used as tie-breaker.
function Get-PackRevision {
    param([string]$FileName)
    if ($FileName -match '_a(\d+)(?:\.zip)?$') {
        return [int]$Matches[1]
    }
    # Some Lenovo packs use v or r suffix: _v2, _r3
    if ($FileName -match '[_\-](?:v|r)(\d+)(?:\.zip)?$') {
        return [int]$Matches[1]
    }
    return 0
}

#  Parse ZIP/folder name into structured metadata
#  Works with Dell, Lenovo, and generic naming conventions
function Get-DriverPackInfo {
    param([Parameter(Mandatory, ValueFromPipeline)]$FileItem)
    process {
        if ($FileItem -is [string]) { $FileItem = Get-Item $FileItem -ErrorAction SilentlyContinue }
        if (-not $FileItem) { return $null }

        $name   = $FileItem.Name.ToLower()
        $base   = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $isZip  = $FileItem.Name -match '\.zip$'
        $sizeMB = if ($isZip) { [math]::Round($FileItem.Length/1MB,1) } else { 0 }

        # Detect OS hint anywhere in filename
        $osHint = "unknown"
        if ($base -match 'win11') { $osHint = "win11" }
        elseif ($base -match 'win10') { $osHint = "win10" }

        # Extract platform codes (Dell specific, ignored for scoring purposes)
        $platformCodes = @("tgl","mlk","whl","whl2","rpl","mtl","adl","spr","amd","intel")
        $platform = ""
        foreach ($p in $platformCodes) {
            if ($base -match $p) { $platform = $p; break }
        }

        # Extract screen-size hints (Dell e13/e14/e15/e16)
        $screenHint = ""
        if ($base -match 'e(1[3-9])') { $screenHint = "e$($Matches[1])" }

        # Build modelHint — strip known prefixes: win10_, win11_, lenovo_, sccm_, hp_, dell_
        $modelHint = $base
        $modelHint = $modelHint -replace '^(win\d+|lenovo|sccm|dell|hp|thinkpad)_',''
        $modelHint = $modelHint -replace '_(a\d+)$',''   # strip revision suffix
        $modelHint = $modelHint -replace '_(win\d+)$',''  # strip trailing os
        $modelHint = $modelHint -replace '[_\-]+',''      # collapse separators

        # Strip platform and screen codes to get clean model token
        $cleanHint = $modelHint
        foreach ($p in $platformCodes) { $cleanHint = $cleanHint -replace $p,'' }
        $cleanHint = $cleanHint -replace 'e(1[3-9])','$1' -replace '[_\-]+',''

        return [PSCustomObject]@{
            FileName    = $FileItem.Name
            BaseName    = $base
            OSHint      = $osHint
            ModelHint   = $modelHint
            CleanHint   = $cleanHint
            Platform    = $platform
            ScreenHint  = $screenHint
            SizeMB      = $sizeMB
            IsZip       = $isZip
            FullPath    = $FileItem.FullName
            DisplayName = if ($isZip) { "$base  [$sizeMB MB]" } else { "$($FileItem.Name)  [folder]" }
        }
    }
}

#  Score a parsed pack against detected WMI model
#  Vendor-agnostic: works with Dell, Lenovo, HP, and generic names
function Get-PackMatchScore {
    <#
    Scoring rubric:
      5 = exact clean string match
      4 = 4-digit model number found in both after normalizing
      3 = strong substring containment
      2 = family + partial model
      1 = family only
      0 = no match
    Auto-select threshold: >= 3
    #>
    param($Info, [string]$ModelKey, [string]$ModelRaw)

    $hint  = if ($Info.ModelHint) { $Info.ModelHint.ToLower() -replace "[\s\-_]","" } else { "" }
    $clean = if ($Info.CleanHint) { $Info.CleanHint.ToLower() -replace "[\s\-_]","" } else { "" }
    $key   = if ($ModelKey)       { $ModelKey.ToLower()       -replace "[\s\-_]","" } else { "" }
    $raw   = if ($ModelRaw)       { $ModelRaw.ToLower()       -replace "[\s\-_ ]","" } else { "" }

    # Extract 4-digit model number from WMI string (e.g. "5550" from "Latitude 5550")
    $modelNum = ""
    if ($raw -match '(\d{4})') { $modelNum = $Matches[1] }

    $score = 0

    # Exact full match
    if ($hint -eq $key -or $clean -eq $key)  { return 5 }
    if ($hint -eq $raw -or $clean -eq $raw)  { return 5 }

    # 4-digit model number match — reliable across all vendors
    if ($modelNum -and $hint  -like "*$modelNum*") { $score += 4 }
    if ($modelNum -and $clean -like "*$modelNum*") { $score += 3 }

    # Substring containment
    if ($key  -like "*$hint*")  { $score += 2 }
    if ($hint -like "*$key*")   { $score += 2 }
    if ($raw  -like "*$hint*")  { $score += 1 }
    if ($hint -like "*$raw*")   { $score += 1 }

    # Vendor family prefix bonus
    $families = @(
        # Dell
        "latitude","optiplex","precision","vostro","inspiron","xps","wyse","alienware","dellpro",
        # Lenovo
        "thinkpad","thinkcentre","thinkstation","ideapad","legion","yoga",
        # HP
        "elitebook","probook","zbook","envy","omen","hp"
    )
    foreach ($fam in $families) {
        if ($hint -match "^$fam" -and $key -match "^$fam") {
            $score += 1
            break
        }
    }

    return $score
}

#  Enumerate all ZIP packs for GUI display
function Get-AllDriverPacks {
    param([string]$DriversRoot = "Z:\Drivers")
    if (-not (Test-Path $DriversRoot)) { return @() }
    return Get-ChildItem $DriversRoot -Filter "*.zip" -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { Get-DriverPackInfo $_ } |
        Where-Object { $_ }
}
