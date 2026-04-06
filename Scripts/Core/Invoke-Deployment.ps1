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
. "$ScriptRoot\Hardware\Get-HardwareModel.ps1"

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
        [int]$ImageIndex        = 1,   # Stock Microsoft WIMs use index 1
        [int]$TargetDisk        = 0,
        [object]$DriverPackIsZip = $null,   # auto-detect if not specified
        [scriptblock]$ProgressCallback,
        [bool]$ConfirmWipe      = $false,
        [object]$DeployConfig   = $null
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
        try { $modelInfo = Get-HardwareInfo } catch { $modelInfo = $null }
        if ($null -eq $modelInfo) {
            $modelInfo = [PSCustomObject]@{
                Manufacturer="Unknown"; Model="Unknown"; ServiceTag="Unknown"
                BIOSVersion="Unknown"; Vendor="Generic"; ModelKey="unknown"
            }
        }

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

        #  Step 6: Write deploy-time unattend.xml + SetupComplete.cmd
        Update-Progress 88 "Writing deployment configuration..."

        # XML escape helper — defined outside try/catch so it's always in scope
        function Esc-Xml {
            param([string]$s)
            if (-not $s) { return $s }
            return $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&apos;'
        }

        try {
            # - Read all settings from runtime config -
            $nameTemplate = ""
            $tz           = "Eastern Standard Time"
            $org          = "Organization"
            $owner        = "User"
            $domain       = ""
            $domainOU     = ""
            $prodKey      = ""
            $domainUser   = ""
            $domainPass   = ""
            $wifiSSID     = ""
            $wifiPass     = ""
            $inputLocale  = "0409:00000409"
            $systemLocale = "en-US"
            $userLocale   = "en-US"
            $appsConfig   = $null

            if ($DeployConfig) {
                try { if ($DeployConfig.Deployment.ComputerNameTemplate) { $nameTemplate = $DeployConfig.Deployment.ComputerNameTemplate } } catch {}
                try { if ($DeployConfig.Deployment.Timezone)             { $tz           = $DeployConfig.Deployment.Timezone } }              catch {}
                try { if ($DeployConfig.Deployment.DomainName)           { $domain       = $DeployConfig.Deployment.DomainName } }            catch {}
                try { if ($DeployConfig.Deployment.DomainOU)             { $domainOU     = $DeployConfig.Deployment.DomainOU } }              catch {}
                try { if ($DeployConfig.Deployment.ProductKey)           { $prodKey      = $DeployConfig.Deployment.ProductKey } }            catch {}
                try { if ($DeployConfig.Deployment.WifiSSID)             { $wifiSSID     = $DeployConfig.Deployment.WifiSSID } }              catch {}
                try { if ($DeployConfig.Deployment.WifiPassword)         { $wifiPass     = $DeployConfig.Deployment.WifiPassword } }          catch {}
                try { if ($DeployConfig.Deployment.InputLocale)          { $inputLocale  = $DeployConfig.Deployment.InputLocale } }           catch {}
                try { if ($DeployConfig.Deployment.SystemLocale)         { $systemLocale = $DeployConfig.Deployment.SystemLocale } }          catch {}
                try { if ($DeployConfig.Deployment.UserLocale)           { $userLocale   = $DeployConfig.Deployment.UserLocale } }            catch {}
                try { if ($DeployConfig.App.OrgName)                     { $org          = $DeployConfig.App.OrgName } }                     catch {}
                try { if ($DeployConfig.DomainCredentials.Username)      { $domainUser   = $DeployConfig.DomainCredentials.Username } }       catch {}
                try { if ($DeployConfig.DomainCredentials.Password)      { $domainPass   = $DeployConfig.DomainCredentials.Password } }       catch {}
                try { if ($DeployConfig.Apps)                            { $appsConfig   = $DeployConfig.Apps } }                            catch {}
            }

            # - Resolve computer name from template + hardware -
            $computerName = "*"
            if ($nameTemplate -and $modelInfo) {
                $computerName = $nameTemplate `
                    -replace '%SERVICETAG%', $modelInfo.ServiceTag `
                    -replace '%MODEL%', ($modelInfo.ModelKey -replace '[^a-zA-Z0-9\-]','') `
                    -replace '%VENDOR%', $modelInfo.Vendor
                # Sanitize: strip characters illegal in NetBIOS names, enforce 15-char limit
                $computerName = $computerName -replace '[^a-zA-Z0-9\-]',''
                if ($computerName.Length -gt 15) { $computerName = $computerName.Substring(0, 15) }
                if (-not $computerName) { $computerName = "*" }
                Write-LogInfo -Msg "Computer name resolved: $computerName (template: $nameTemplate)" -Comp "Deploy"
            } else {
                Write-LogInfo -Msg "No ComputerNameTemplate configured - Windows will auto-name" -Comp "Deploy"
            }

            # - Build product key XML snippet (specialize pass) -
            # NOTE: If the key doesn't match the WIM edition, specialize fails with 0xc004f050.
            # We validate the format (5x5 alphanumeric) and wrap in try-catch-style approach:
            # Use Microsoft-Windows-Shell-Setup/ProductKey in specialize only if key looks valid.
            $productKeyXml = ""
            if ($prodKey -and ($prodKey -match '^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$')) {
                $productKeyXml = "      <ProductKey>$(Esc-Xml $prodKey)</ProductKey>"
                Write-LogInfo -Msg "Product key configured (MAK)" -Comp "Deploy"
            } elseif ($prodKey) {
                Write-LogWarn -Msg "Product key format invalid, skipping to avoid specialize failure: $prodKey" -Comp "Deploy"
            }

            # - Build domain join XML snippet (specialize pass) -
            # Modeled after Dell Image Assist: Credentials before JoinDomain, Password as simple string
            # Strip domain prefix from username (domain\user -> user) since Domain element handles it
            $domainJoinXml = ""
            if ($domain -and $domainUser) {
                $joinUser = $domainUser
                if ($joinUser -match '\\') { $joinUser = ($joinUser -split '\\', 2)[1] }
                $ouLine = ""
                if ($domainOU) { $ouLine = "`n        <MachineObjectOU>$(Esc-Xml $domainOU)</MachineObjectOU>" }
                $domainJoinXml = @"
    <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Identification>
        <Credentials>
          <Domain>$(Esc-Xml $domain)</Domain>
          <Password>$(Esc-Xml $domainPass)</Password>
          <Username>$(Esc-Xml $joinUser)</Username>
        </Credentials>
        <JoinDomain>$(Esc-Xml $domain)</JoinDomain>$ouLine
      </Identification>
    </component>
"@
                Write-LogInfo -Msg "Domain join configured: $domain (user: $joinUser)" -Comp "Deploy"
            }

            # - Escape locale values for XML -
            $escInputLocale  = Esc-Xml $inputLocale
            $escSystemLocale = Esc-Xml $systemLocale
            $escUserLocale   = Esc-Xml $userLocale

            # - Generate unattend.xml (modeled after Dell Image Assist structure) -
            $unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>$(Esc-Xml $computerName)</ComputerName>
$productKeyXml
      <RegisteredOrganization>$(Esc-Xml $org)</RegisteredOrganization>
      <TimeZone>$(Esc-Xml $tz)</TimeZone>
    </component>
$domainJoinXml
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Description>EnableAdmin</Description>
          <Path>cmd /c net user Administrator /active:yes</Path>
          <Order>1</Order>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Description>UnfilterAdminToken</Description>
          <Path>cmd /c reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v FilterAdministratorToken /t REG_DWORD /d 0 /f</Path>
          <Order>2</Order>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Description>DEFAULT_UAC_EnableLUA</Description>
          <Path>cmd /c reg ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA /t REG_DWORD /d 1 /f</Path>
          <Order>3</Order>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Description>DEFAULT_UAC_ConsentPromptBehaviorAdmin</Description>
          <Path>cmd /c reg ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 5 /f</Path>
          <Order>4</Order>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Description>DEFAULT_UAC_PromptOnSecureDesktop</Description>
          <Path>cmd /c reg ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v PromptOnSecureDesktop /t REG_DWORD /d 1 /f</Path>
          <Order>5</Order>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Description>BypassNRO</Description>
          <Path>cmd /c reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
          <Order>6</Order>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>$escInputLocale</InputLocale>
      <SystemLocale>$escSystemLocale</SystemLocale>
      <UILanguage>$escSystemLocale</UILanguage>
      <UILanguageFallback>$escSystemLocale</UILanguageFallback>
      <UserLocale>$escUserLocale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts>
        <AdministratorPassword>
          <Value>DynPxE2024!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Description></Description>
            <DisplayName></DisplayName>
            <Name>tempadmin</Name>
            <Group>Administrators</Group>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <ProtectYourPC>1</ProtectYourPC>
      </OOBE>
      <TimeZone>$(Esc-Xml $tz)</TimeZone>
      <RegisteredOwner>$(Esc-Xml $org)</RegisteredOwner>
    </component>
  </settings>
</unattend>
"@
            $pantherDir = "$osDrive\Windows\Panther"
            if (-not (Test-Path $pantherDir)) { New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null }
            $unattendXml | Set-Content -Path "$pantherDir\unattend.xml" -Encoding UTF8 -Force
            Write-LogInfo -Msg "Deploy unattend.xml written to $pantherDir\unattend.xml" -Comp "Deploy"
            Update-Progress 89 "Unattend.xml written (Name: $computerName)"

            # - Generate SetupComplete.cmd -
            $scriptDir = "$osDrive\Windows\Setup\Scripts"
            if (-not (Test-Path $scriptDir)) { New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null }

            $logDir  = "C:\DynamicPxE\Logs"
            $logFile = "$logDir\SetupComplete.log"

            $cmdLines = [System.Collections.ArrayList]@()
            [void]$cmdLines.Add("@echo off")
            [void]$cmdLines.Add(":: ==========================================================")
            [void]$cmdLines.Add("::  SetupComplete.cmd - Generated by DynamicPxE")
            [void]$cmdLines.Add("::  Runs after Windows setup, before first user logon")
            [void]$cmdLines.Add(":: ==========================================================")
            [void]$cmdLines.Add("")
            [void]$cmdLines.Add(":: Create log directory")
            [void]$cmdLines.Add("if not exist `"$logDir`" mkdir `"$logDir`"")
            [void]$cmdLines.Add("echo [%date% %time%] SetupComplete.cmd started >> `"$logFile`"")
            [void]$cmdLines.Add("")

            # WiFi profile import (profile only - no forced connect to avoid disrupting ethernet)
            if ($wifiSSID -and $wifiPass) {
                Write-LogInfo -Msg "Adding WiFi profile to SetupComplete: $wifiSSID" -Comp "Deploy"

                $wifiProfileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$wifiSSID</name>
  <SSIDConfig>
    <SSID>
      <name>$wifiSSID</name>
    </SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$wifiPass</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
                $wifiDir = "$osDrive\DynamicPxE\WiFi"
                if (-not (Test-Path $wifiDir)) { New-Item -Path $wifiDir -ItemType Directory -Force | Out-Null }
                $wifiProfileXml | Set-Content -Path "$wifiDir\$wifiSSID.xml" -Encoding UTF8 -Force

                [void]$cmdLines.Add(":: - WiFi Configuration (import only, no forced connect) -")
                [void]$cmdLines.Add(":: Profile is imported so Windows auto-connects when ethernet is unavailable")
                [void]$cmdLines.Add("echo [%date% %time%] Importing WiFi profile: $wifiSSID >> `"$logFile`"")
                [void]$cmdLines.Add("netsh wlan add profile filename=`"C:\DynamicPxE\WiFi\$wifiSSID.xml`" >> `"$logFile`" 2>&1")
                [void]$cmdLines.Add("echo [%date% %time%] WiFi profile imported (auto-connect when no ethernet) >> `"$logFile`"")
                [void]$cmdLines.Add("")
            }

            # App installations from network share (public share, no credentials)
            $hasApps = $false
            if ($appsConfig -and $appsConfig.Packages -and @($appsConfig.Packages).Count -gt 0) {
                $hasApps = $true
                $appSharePath  = if ($appsConfig.SharePath) { $appsConfig.SharePath } else { "" }
                $appDrive      = if ($appsConfig.DriveLetter) { $appsConfig.DriveLetter } else { "Y:" }

                [void]$cmdLines.Add(":: - Map App Share (public, no credentials) -")
                [void]$cmdLines.Add("echo [%date% %time%] Mapping app share: $appSharePath >> `"$logFile`"")
                [void]$cmdLines.Add("net use $appDrive `"$appSharePath`" /persistent:no >> `"$logFile`" 2>&1")

                [void]$cmdLines.Add("if %ERRORLEVEL% NEQ 0 (")
                [void]$cmdLines.Add("    echo [%date% %time%] ERROR: Failed to map app share >> `"$logFile`"")
                [void]$cmdLines.Add("    goto :cleanup")
                [void]$cmdLines.Add(")")
                [void]$cmdLines.Add("echo [%date% %time%] App share mapped to $appDrive >> `"$logFile`"")
                [void]$cmdLines.Add("")

                [void]$cmdLines.Add(":: - Install Applications -")
                $appIndex = 0
                foreach ($app in @($appsConfig.Packages)) {
                    $appIndex++
                    $appName = $app.Name
                    $appPath = $app.Path
                    $appArgs = $app.Args

                    # Determine installer type from extension
                    $fullPath = "$appDrive\$appPath"
                    $isMsi = $appPath -match '\.msi$'

                    [void]$cmdLines.Add(":: App $appIndex`: $appName")
                    [void]$cmdLines.Add("echo [%date% %time%] Installing [$appIndex]: $appName >> `"$logFile`"")
                    [void]$cmdLines.Add("if exist `"$fullPath`" (")

                    if ($isMsi) {
                        [void]$cmdLines.Add("    msiexec /i `"$fullPath`" $appArgs >> `"$logFile`" 2>&1")
                    } else {
                        [void]$cmdLines.Add("    start /wait `"`" `"$fullPath`" $appArgs >> `"$logFile`" 2>&1")
                    }

                    [void]$cmdLines.Add("    if %ERRORLEVEL% EQU 0 (")
                    [void]$cmdLines.Add("        echo [%date% %time%] SUCCESS: $appName installed >> `"$logFile`"")
                    [void]$cmdLines.Add("    ) else (")
                    [void]$cmdLines.Add("        echo [%date% %time%] WARNING: $appName exited with code %ERRORLEVEL% >> `"$logFile`"")
                    [void]$cmdLines.Add("    )")
                    [void]$cmdLines.Add(") else (")
                    [void]$cmdLines.Add("    echo [%date% %time%] ERROR: Installer not found: $fullPath >> `"$logFile`"")
                    [void]$cmdLines.Add(")")
                    [void]$cmdLines.Add("")
                }
            }

            # Cleanup section
            [void]$cmdLines.Add(":cleanup")
            if ($hasApps) {
                $appDriveCleanup = if ($appsConfig.DriveLetter) { $appsConfig.DriveLetter } else { "Y:" }
                [void]$cmdLines.Add(":: - Disconnect app share -")
                [void]$cmdLines.Add("net use $appDriveCleanup /delete /y >nul 2>&1")
            }
            [void]$cmdLines.Add("")
            [void]$cmdLines.Add("echo [%date% %time%] SetupComplete.cmd finished >> `"$logFile`"")
            [void]$cmdLines.Add("echo. >> `"$logFile`"")

            $setupCompletePath = "$scriptDir\SetupComplete.cmd"
            ($cmdLines -join "`r`n") | Set-Content -Path $setupCompletePath -Encoding ASCII -Force
            Write-LogInfo -Msg "SetupComplete.cmd written to $setupCompletePath" -Comp "Deploy"

            if ($hasApps) {
                Write-LogInfo -Msg "$(@($appsConfig.Packages).Count) app(s) queued for post-setup install" -Comp "Deploy"
            }
            Update-Progress 90 "Configuration written (Name: $computerName, Apps: $(if ($hasApps) { @($appsConfig.Packages).Count } else { 0 }))"
        } catch {
            Write-LogWarn -Msg "STEP 6 FAILED: $($_.Exception.Message)" -Comp "Deploy"
            Write-LogWarn -Msg "Stack: $($_.ScriptStackTrace)" -Comp "Deploy"
            if ($ProgressCallback) { & $ProgressCallback -1 "WARNING: unattend.xml/SetupComplete.cmd not written - $($_.Exception.Message)" }
        }

        #  Step 7: Configure boot
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
