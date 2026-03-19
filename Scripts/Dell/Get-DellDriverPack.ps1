# ============================================================
#  Get-DellDriverPack.ps1  (v2 - calibrated against real share)
#
#  Real share inventory observed:
#    win10_latitudee10_a23.zip
#    win10_latitudee11whl2_a15.zip
#    win10_latitudee11whl_a20.zip
#    win10_latitudee13tgl5320_a06.zip
#    win10_latitudee13tgl5520_a06.zip
#    win10_latitudee14mlk5530_a03.zip
#    win10_optiplexd11_a12.zip
#    win10_optiplexd12_a03.zip
#    win10_optiplexd9mlk_a15.zip
#    win10_optiplexd9_a23.zip
#    win10_precisionm10mlk3550_a12.zip
#    win10_precisionm8whl_a14.zip
#    win10_precisionws10_a11.zip
#    win11_dellprolaptopse17pc16250rpl_a05.zip
#    win11_latitude5550_a06.zip
#    win11_latitudee13tgl5320_a17.zip
#    win11_latitudee13tgl5520_a18.zip
#    win11_latitudee14mlk5530_a16.zip
#    win11_latitudee16mtl5550_a12.zip
#    Win11_latitudee5550_a19.zip    <- capital W, note e5550 vs 5550
#    win11_optiplexd11_a21.zip
#    win11_optiplexd12_a14.zip
#    win11_optiplexd13mlk7020_a09.zip
#    win11_optiplexd13mlk7020_a17.zip
#    win11_precisionm11tgl3560_a19.zip
#    win11_latitude5550_a06\        <- pre-extracted folder
#
#  Dell token decoding:
#    "latitudee10"      -> Latitude E10 (legacy E-series)
#    "latitude5550"     -> Latitude 5550
#    "latitudee5550"    -> Latitude 5550 (E prefix used on some packs)
#    "latitudee16mtl5550" -> Latitude 5550 with MTL platform, 16" screen
#    "latitudee13tgl5320" -> Latitude 5320 with TGL platform, 13"
#    "optiplexd11"      -> OptiPlex 3000/5000/7000 gen11 family shorthand
#    "optiplexd12"      -> OptiPlex gen12 family
#    "optiplexd13mlk7020" -> OptiPlex 7020 with MLK platform
#    "precisionm10mlk3550"-> Precision 3550 mobile gen10
#    "precisionm8whl"   -> Precision mobile gen8 WHl platform
#    "precisionws10"    -> Precision workstation gen10
#    "dellprolaptopse17pc16250rpl" -> opaque; extract family+screen hint
# ============================================================

function Get-DellDriverPack {
    [CmdletBinding()]
    param(
        [string]$ModelKey,
        [string]$ModelRaw,
        [string]$DriversRoot = "Z:\Drivers",
        [string]$MapFile     = "X:\Deploy\Config\DellDriverMap.json"
    )

    if (-not $ModelKey -or -not $ModelRaw) {
        $modelInfo = Get-DellModel
        if (-not $ModelKey) { $ModelKey = $modelInfo.ModelKey }
        if (-not $ModelRaw) { $ModelRaw = $modelInfo.Model }
    }

    Write-LogInfo -Msg "Driver lookup - Key:'$ModelKey'  Raw:'$ModelRaw'" -Comp "DellDriverPack"

    $zipResult    = $null
    $folderResult = $null
    $matchType    = "None"

    #  1. JSON exact match 
    $map = $null
    if (Test-Path $MapFile) {
        try { $map = Get-Content $MapFile -Raw | ConvertFrom-Json }
        catch { Write-LogWarn -Msg "JSON parse failed: $_" -Comp "DellDriverPack" }
    }

    if ($map) {
        $entry = $map.Mappings | Where-Object { $_.ModelKey -eq $ModelKey } | Select-Object -First 1
        if ($entry) {
            if ($entry.ZipFile)          { $zipResult    = $entry.ZipFile;      $matchType = "Exact-JSON-ZIP"    }
            elseif ($entry.DriverFolder) { $folderResult = $entry.DriverFolder; $matchType = "Exact-JSON-Folder" }
        }
        # Fuzzy JSON
        if (-not $zipResult -and -not $folderResult) {
            $entry = $map.Mappings | Where-Object {
                $ModelKey -like "*$($_.ModelKey)*" -or $_.ModelKey -like "*$ModelKey*"
            } | Select-Object -First 1
            if ($entry) {
                if ($entry.ZipFile)          { $zipResult    = $entry.ZipFile;      $matchType = "Fuzzy-JSON-ZIP"    }
                elseif ($entry.DriverFolder) { $folderResult = $entry.DriverFolder; $matchType = "Fuzzy-JSON-Folder" }
                Write-LogWarn -Msg "Fuzzy JSON match ($matchType) - verify" -Comp "DellDriverPack"
            }
        }
    }

    #  2. ZIP filename scoring 
    if (-not $zipResult -and -not $folderResult -and (Test-Path $DriversRoot)) {
        Write-LogInfo -Msg "Scanning share ZIPs..." -Comp "DellDriverPack"
        $zips = Get-ChildItem -Path $DriversRoot -Filter "*.zip" -ErrorAction SilentlyContinue

        if ($zips) {
            $results = $zips | ForEach-Object {
                $info        = Get-DriverPackInfo $_
                $score       = Get-ZipMatchScore -Info $info -ModelKey $ModelKey -ModelRaw $ModelRaw
                $revision    = Get-PackRevision $_.Name
                $osPref      = if ($info.OSHint -eq "win11") { 1 } else { 0 }
                Write-LogDebug -Msg "  $($_.Name) | os:$($info.OSHint) score:$score osPref:$osPref rev:$revision" -Comp "DellDriverPack"
                [PSCustomObject]@{ File = $_.Name; Score = $score; OSPreference = $osPref; Revision = $revision; Info = $info }
            }

            # Sort priority:
            #   1. Score DESC          (best model match wins)
            #   2. OSPreference DESC   (win11=1 beats win10=0)
            #   3. Revision DESC       (a19 beats a06)
            $results = $results | Sort-Object -Property @(
                @{Expression = "Score";        Descending = $true},
                @{Expression = "OSPreference"; Descending = $true},
                @{Expression = "Revision";     Descending = $true}
            )

            $best = $results | Select-Object -First 1
            if ($best -and $best.Score -ge 3) {
                $zipResult = $best.File
                $matchType = "ZIP-Scan (score=$($best.Score) rev=a$($best.Revision))"
                $osLabel = if ($best.OSPreference -eq 1) { "win11" } else { "win10" }
                Write-LogInfo -Msg "Best ZIP: $zipResult (score $($best.Score), $osLabel, rev a$($best.Revision))" -Comp "DellDriverPack"

                # Log all qualifying candidates so you can audit the choice
                $candidates = $results | Where-Object { $_.Score -ge 3 }
                if ($candidates.Count -gt 1) {
                    Write-LogInfo -Msg "All qualifying candidates (sorted by priority):" -Comp "DellDriverPack"
                    $candidates | ForEach-Object {
                        $ol = if ($_.OSPreference -eq 1) { "win11" } else { "win10" }
                        Write-LogInfo -Msg "  score=$($_.Score) $ol rev=a$($_.Revision)  $($_.File)" -Comp "DellDriverPack"
                    }
                }
            } elseif ($best) {
                Write-LogWarn -Msg "Best score $($best.Score) < 3 - no auto-match. User must select." -Comp "DellDriverPack"
            }
        }
    }

    #  3. Pre-extracted folder fallback (not expected in normal use) 
    # All packs should be ZIPs on the share. This handles edge cases.
    if (-not $zipResult -and -not $folderResult -and (Test-Path $DriversRoot)) {
        $dirs = Get-ChildItem -Path $DriversRoot -Directory -ErrorAction SilentlyContinue
        if ($dirs) {
            $match = $dirs | ForEach-Object {
                $info  = Get-DriverPackInfo $_
                $score = Get-ZipMatchScore -Info $info -ModelKey $ModelKey -ModelRaw $ModelRaw
                [PSCustomObject]@{ Name = $_.Name; Score = $score }
            } | Sort-Object Score -Descending | Select-Object -First 1

            if ($match -and $match.Score -ge 3) {
                $folderResult = $match.Name
                $matchType    = "Folder-Scan (score=$($match.Score))"
                Write-LogInfo -Msg "Folder fallback match: $folderResult" -Comp "DellDriverPack"
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
        Write-LogWarn -Msg "No driver pack matched for '$ModelKey'. User must select manually." -Comp "DellDriverPack"
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

#  Extract numeric revision from Dell pack filename 
# e.g. "win11_latitude5550_a06.zip" -> 6
#       "win11_optiplexd13mlk7020_a17.zip" -> 17
# Higher value = newer pack. Used as tie-breaker when score is equal.
function Get-PackRevision {
    param([string]$FileName)
    if ($FileName -match '_a(\d+)(?:\.zip)?$') {
        return [int]$Matches[1]
    }
    return 0
}

#  Parse Dell ZIP/folder name into structured metadata 
function Get-DriverPackInfo {
    param([Parameter(Mandatory, ValueFromPipeline)]$FileItem)
    process {
        if ($FileItem -is [string]) { $FileItem = Get-Item $FileItem -ErrorAction SilentlyContinue }
        if (-not $FileItem) { return $null }

        $name   = $FileItem.Name.ToLower()   # normalize case (handles "Win11_...")
        $base   = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $isZip  = $FileItem.Name -match '\.zip$'
        $sizeMB = if ($isZip) { [math]::Round($FileItem.Length/1MB,1) } else { 0 }

        # Pattern: {os}_{modeltoken}_{version}  or  {os}_{modeltoken}
        $osHint    = "unknown"
        $modelHint = $base
        $version   = ""
        $platform  = ""   # extracted platform code (tgl,mlk,whl,rpl,mtl...)
        $screenHint = ""  # e.g. "e16", "e13", "e14"

        if ($base -match '^(win\d+)_(.+?)_(a\d+)$') {
            $osHint    = $Matches[1]
            $modelHint = $Matches[2]
            $version   = $Matches[3]
        } elseif ($base -match '^(win\d+)_(.+)$') {
            $osHint    = $Matches[1]
            $modelHint = $Matches[2]
        }

        # Extract embedded platform codes
        $platformCodes = @("tgl","mlk","whl","whl2","rpl","mtl","adl","spr")
        foreach ($p in $platformCodes) {
            if ($modelHint -match $p) { $platform = $p; break }
        }

        # Extract screen-size hints like e13, e14, e15, e16
        if ($modelHint -match 'e(1[3-9])') { $screenHint = "e$($Matches[1])" }

        # Strip platform and screen codes to get clean model token
        $cleanHint = $modelHint
        foreach ($p in $platformCodes) { $cleanHint = $cleanHint -replace $p,'' }
        $cleanHint = $cleanHint -replace 'e(1[3-9])','$1' -replace '[_\-]+',''

        return [PSCustomObject]@{
            FileName    = $FileItem.Name
            BaseName    = $base
            OSHint      = $osHint       # "win10" or "win11"
            ModelHint   = $modelHint    # raw token: "latitudee16mtl5550"
            CleanHint   = $cleanHint    # stripped:  "latitudee5550" -> "latitudee5550"
            Platform    = $platform     # "tgl","mlk", etc.
            ScreenHint  = $screenHint
            Version     = $version
            SizeMB      = $sizeMB
            IsZip       = $isZip
            FullPath    = $FileItem.FullName
            DisplayName = if ($isZip) { "$base  [$sizeMB MB]" } else { "$($FileItem.Name)  [folder]" }
        }
    }
}

#  Score a parsed pack against detected WMI model 
function Get-ZipMatchScore {
    <#
    Scoring rubric (higher = better):
      5 = exact clean string match
      4 = model number found in both after normalizing
      3 = strong substring containment
      2 = family + partial model
      1 = family only
      0 = no match
    Threshold to auto-select: >= 3
    #>
    param($Info, [string]$ModelKey, [string]$ModelRaw)

    # Normalize everything to lowercase, strip spaces/hyphens
    $hint  = if ($null -ne $Info.ModelHint -and $Info.ModelHint -ne "") { $Info.ModelHint.ToLower() -replace "[\s\-_]","" } else { "" }
    $clean = if ($null -ne $Info.CleanHint -and $Info.CleanHint -ne "") { $Info.CleanHint.ToLower() -replace "[\s\-_]","" } else { "" }
    $key   = if ($null -ne $ModelKey -and $ModelKey -ne "") { $ModelKey.ToLower() -replace "[\s\-_]","" } else { "" }
    $raw   = if ($null -ne $ModelRaw -and $ModelRaw -ne "") { $ModelRaw.ToLower() -replace "[\s\-_ ]","" } else { "" }

    # Extract just the numeric model number from WMI (e.g. "5550" from "Latitude 5550")
    $modelNum = ""
    if ($raw -match '(\d{4})') { $modelNum = $Matches[1] }

    $score = 0

    # Exact full matches
    if ($hint -eq $key -or $clean -eq $key)  { return 5 }
    if ($hint -eq $raw -or $clean -eq $raw)  { return 5 }

    # Model number match (most reliable for Dell)
    # e.g. "latitude5550" contains "5550" and WMI raw also contains "5550"
    if ($modelNum -and $hint  -like "*$modelNum*") { $score += 4 }
    if ($modelNum -and $clean -like "*$modelNum*") { $score += 3 }

    # Substring containment
    if ($key  -like "*$hint*")  { $score += 2 }
    if ($hint -like "*$key*")   { $score += 2 }
    if ($raw  -like "*$hint*")  { $score += 1 }
    if ($hint -like "*$raw*")   { $score += 1 }

    # Family prefix match
    $families = @("latitude","optiplex","precision","vostro","inspiron","xps","wyse","alienware","dellpro")
    foreach ($fam in $families) {
        if ($hint -match "^$fam" -and $key -match "^$fam") {
            $score += 1   # same family bonus
            break
        }
    }

    return $score
}

#  Public: enumerate all ZIP packs for GUI 
function Get-AllDriverPacks {
    param([string]$DriversRoot = "Z:\Drivers")
    if (-not (Test-Path $DriversRoot)) { return @() }
    # Sort by name so GUI list is ordered; within same model, higher 'a' appears last
    # (GUI selection is what matters - user can override auto-match)
    return Get-ChildItem $DriversRoot -Filter "*.zip" -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { Get-DriverPackInfo $_ } |
        Where-Object { $_ }
}