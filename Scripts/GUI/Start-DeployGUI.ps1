# ============================================================
#  Start-DeployGUI.ps1
#  WinPE deployment wizard using the DynamicPxE GUI Framework
#  Launched by startnet.cmd at WinPE boot
#
#  Pages:
#    1. Connect    — network credentials + share mapping
#    2. Select     — image & driver pack selection
#    3. Configure  — disk target, image index, options
#    4. Deploy     — progress, log viewer, reboot countdown
# ============================================================

#Requires -Version 5.1

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# - Paths --------------------------
$ScriptRoot = "X:\Deploy\Scripts"
$ConfigRoot = "X:\Deploy\Config"

# - Load framework (provides theme, layout, controls, pages) ─
. "$ScriptRoot\GUI\Framework\Initialize-GUIFramework.ps1"

# - Load core modules --------------------
. "$ScriptRoot\Logging\Write-DeployLog.ps1"
. "$ScriptRoot\Core\Map-NetworkShare.ps1"
. "$ScriptRoot\Core\Invoke-Deployment.ps1"
. "$ScriptRoot\Hardware\Get-HardwareModel.ps1"
. "$ScriptRoot\Hardware\Get-DriverPack.ps1"

Initialize-Log
Write-LogInfo -Msg "Deploy GUI starting..." -Comp "DeployGUI"

# - Load config -----------------------
$ConfigFile = "$ConfigRoot\DeployConfig.json"
$Config = $null
if (Test-Path $ConfigFile) {
    try { $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch {}
}

# - Config defaults ---------------------
$ShareRoot     = "\\server\share"
$DriveLetter   = "Z:"
$ImagesFolder  = "Images"
$DriversFolder = "Drivers"
$AppTitle      = "DynamicPxE"
$AppVersion    = "1.0"
$OrgName       = ""
$BuildLabel    = "WinPE 11  ADK 26100"
$DomainPrefix  = "DOMAIN\"
$DefaultIndex  = 1
$DefaultDisk   = 0
$RebootSecs    = 15
$ComputerNameTemplate = ""
$DomainName    = ""
$DomainOU      = ""
$ProductKey    = ""
$Timezone      = "Eastern Standard Time"
$InputLocale   = "0409:00000409"
$SystemLocale  = "en-US"
$UserLocale    = "en-US"
$WifiSSID      = ""
$WifiPassword  = ""
$AppsConfig    = $null

if ($Config) {
    try { if ($Config.Network.ShareRoot)              { $ShareRoot     = $Config.Network.ShareRoot } }              catch {}
    try { if ($Config.Network.DriveLetter)            { $DriveLetter   = $Config.Network.DriveLetter } }            catch {}
    try { if ($Config.Network.ImagesSubfolder)        { $ImagesFolder  = $Config.Network.ImagesSubfolder } }        catch {}
    try { if ($Config.Network.DriversSubfolder)       { $DriversFolder = $Config.Network.DriversSubfolder } }       catch {}
    try { if ($Config.App.AppTitle)                   { $AppTitle      = $Config.App.AppTitle } }                   catch {}
    try { if ($Config.App.AppVersion)                 { $AppVersion    = $Config.App.AppVersion } }                 catch {}
    try { if ($Config.App.OrgName)                    { $OrgName       = $Config.App.OrgName } }                    catch {}
    try { if ($Config.App.BuildLabel)                 { $BuildLabel    = $Config.App.BuildLabel } }                 catch {}
    try { if ($Config.App.DefaultDomainPrefix)        { $DomainPrefix  = $Config.App.DefaultDomainPrefix } }        catch {}
    try { if ($Config.Deployment.DefaultImageIndex)   { $DefaultIndex  = [int]$Config.Deployment.DefaultImageIndex } } catch {}
    try { if ($Config.Deployment.DefaultTargetDisk)   { $DefaultDisk   = [int]$Config.Deployment.DefaultTargetDisk } } catch {}
    try { if ($Config.Deployment.AutoRebootSeconds)   { $RebootSecs    = [int]$Config.Deployment.AutoRebootSeconds } } catch {}
    try { if ($Config.Deployment.ComputerNameTemplate) { $ComputerNameTemplate = $Config.Deployment.ComputerNameTemplate } } catch {}
    try { if ($Config.Deployment.DomainName)           { $DomainName    = $Config.Deployment.DomainName } }           catch {}
    try { if ($Config.Deployment.DomainOU)             { $DomainOU      = $Config.Deployment.DomainOU } }             catch {}
    try { if ($Config.Deployment.ProductKey)           { $ProductKey    = $Config.Deployment.ProductKey } }           catch {}
    try { if ($Config.Deployment.Timezone)             { $Timezone      = $Config.Deployment.Timezone } }             catch {}
    try { if ($Config.Deployment.InputLocale)          { $InputLocale   = $Config.Deployment.InputLocale } }           catch {}
    try { if ($Config.Deployment.SystemLocale)         { $SystemLocale  = $Config.Deployment.SystemLocale } }          catch {}
    try { if ($Config.Deployment.UserLocale)           { $UserLocale    = $Config.Deployment.UserLocale } }            catch {}
    try { if ($Config.Deployment.WifiSSID)             { $WifiSSID      = $Config.Deployment.WifiSSID } }             catch {}
    try { if ($Config.Deployment.WifiPassword)         { $WifiPassword  = $Config.Deployment.WifiPassword } }         catch {}
    try { if ($Config.Apps)                            { $AppsConfig    = $Config.Apps } }                            catch {}
}

# - Initialize theme from config --------------─
Initialize-Theme -Config $Config

# - Shared state ----------------------─
$script:ShareMapped     = $false
$script:ShareResult     = $null
$script:DeployRunning   = $false
$script:ModelInfo       = $null
$script:SelectedImage   = $null
$script:SelectedDriver  = $null

# - Helper: update log viewer ----------------
function Update-Log {
    param([string]$Msg)
    $timestamp = Get-Date -Format "HH:mm:ss"
    if ($script:rtbLog) {
        $script:rtbLog.AppendText("[$timestamp] $Msg`r`n")
        $script:rtbLog.ScrollToCaret()
    }
    Write-LogInfo -Msg $Msg -Comp "DeployGUI"
}

# ============================================================
#  BUILD APP SHELL
# ============================================================
$titleText = "$AppTitle  -  $BuildLabel"
if ($OrgName) { $titleText += "  |  $OrgName" }

$shell = New-AppShell -Title $titleText -Config $Config -Mode "Deploy"
$form  = $shell.Form

$shell.StatusLeft.Text  = "Deploy Tool  |  Ready"
$shell.StatusRight.Text = "$AppVersion  |  WinPE"

# ============================================================
#  PAGE DEFINITIONS
# ============================================================

# - PAGE 1: Connect ---------------------
$pageConnect = @{
    Name  = "connect"
    Title = "Connect"
    BuildContent = {
        param($parent)

        # Hardware info card
        $hwCard = New-CardPanel -Title "THIS MACHINE" -Parent $parent -Height 80
        $script:lblHWInfo = New-StyledLabel -Text "Detecting hardware..." -FontName "bodyBold"
        New-FullWidthRow -Control $script:lblHWInfo -Table $hwCard.ContentTable -RowIndex 0

        New-SpacerPanel -Height 6 | ForEach-Object { $parent.Controls.Add($_) }

        # Network credentials card
        $netCard = New-CardPanel -Title "NETWORK SHARE" -Parent $parent -Height 200
        $t = $netCard.ContentTable

        $script:txtShare = New-StyledTextBox -Text $ShareRoot
        $script:txtShare.TabIndex = 0
        New-FormRow -Label "Share path" -Control $script:txtShare -Table $t -RowIndex 0

        $script:txtUser = New-StyledTextBox -Text $DomainPrefix
        $script:txtUser.TabIndex = 1
        New-FormRow -Label "Username" -Control $script:txtUser -Table $t -RowIndex 1

        $script:txtPass = New-StyledTextBox -Password
        $script:txtPass.TabIndex = 2
        New-FormRow -Label "Password" -Control $script:txtPass -Table $t -RowIndex 2

        # Connect button + status in a flow panel
        $flowConnect = New-Object System.Windows.Forms.FlowLayoutPanel
        $flowConnect.AutoSize  = $true
        $flowConnect.BackColor = [System.Drawing.Color]::Transparent
        $flowConnect.WrapContents = $false

        $script:btnConnect = New-RoundedButton -Text "Connect" -Width 140 -Height 36
        $script:btnConnect.TabIndex = 3
        $script:lblConnStatus = New-StyledLabel -Text "  Not connected" -FontName "small" -ColorName "TextDim"
        $script:lblConnStatus.AutoSize = $true
        $script:lblConnStatus.Padding = New-Object System.Windows.Forms.Padding(8, 10, 0, 0)

        $flowConnect.Controls.Add($script:btnConnect)
        $flowConnect.Controls.Add($script:lblConnStatus)
        New-FullWidthRow -Control $flowConnect -Table $t -RowIndex 3

        # Logo (optional, below credentials)
        $logoPng = "X:\Deploy\Resources\logo.png"
        if ($Config) {
            try { if ($Config.Branding.LogoPath) { $logoPng = $Config.Branding.LogoPath } } catch {}
        }
        if (Test-Path $logoPng) {
            try {
                New-SpacerPanel -Height 12 | ForEach-Object { $parent.Controls.Add($_) }
                $picBox = New-Object System.Windows.Forms.PictureBox
                $picBox.Image    = [System.Drawing.Image]::FromFile($logoPng)
                $picBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
                $picBox.Dock     = [System.Windows.Forms.DockStyle]::Top
                $picBox.Height   = Get-ScaledValue 120
                $picBox.BackColor = [System.Drawing.Color]::Transparent
                $parent.Controls.Add($picBox)
            } catch {}
        }

        return @{
            txtShare      = $script:txtShare
            txtUser       = $script:txtUser
            txtPass       = $script:txtPass
            btnConnect    = $script:btnConnect
            lblConnStatus = $script:lblConnStatus
            lblHWInfo     = $script:lblHWInfo
        }
    }
}

# - PAGE 2: Select Image & Drivers -------------─
$pageSelect = @{
    Name  = "select"
    Title = "Select"
    BuildContent = {
        param($parent)

        # Image selection card
        $imgCard = New-CardPanel -Title "OS IMAGE (.wim)" -Parent $parent -Height 260
        $script:lbImages = New-StyledListBox -Height 140
        New-FullWidthRow -Control $script:lbImages -Table $imgCard.ContentTable -RowIndex 0

        $flowImg = New-Object System.Windows.Forms.FlowLayoutPanel
        $flowImg.AutoSize  = $true
        $flowImg.BackColor = [System.Drawing.Color]::Transparent
        $script:btnRefreshImg = New-RoundedButton -Text "Refresh" -Width 100 -Height 30 -Secondary
        $script:lblImgCount = New-StyledLabel -Text "  Connect to share first" -FontName "small" -ColorName "TextDim"
        $script:lblImgCount.AutoSize = $true
        $script:lblImgCount.Padding = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
        $flowImg.Controls.Add($script:btnRefreshImg)
        $flowImg.Controls.Add($script:lblImgCount)
        New-FullWidthRow -Control $flowImg -Table $imgCard.ContentTable -RowIndex 1

        New-SpacerPanel -Height 6 | ForEach-Object { $parent.Controls.Add($_) }

        # Driver pack card
        $drvCard = New-CardPanel -Title "DRIVER PACK (.zip)" -Parent $parent -Height 260
        $script:lbDrivers = New-StyledListBox -Height 140
        New-FullWidthRow -Control $script:lbDrivers -Table $drvCard.ContentTable -RowIndex 0

        $flowDrv = New-Object System.Windows.Forms.FlowLayoutPanel
        $flowDrv.AutoSize  = $true
        $flowDrv.BackColor = [System.Drawing.Color]::Transparent
        $script:btnRefreshDrv = New-RoundedButton -Text "Refresh" -Width 100 -Height 30 -Secondary
        $script:lblDrvCount = New-StyledLabel -Text "  Connect to share first" -FontName "small" -ColorName "TextDim"
        $script:lblDrvCount.AutoSize = $true
        $script:lblDrvCount.Padding = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
        $flowDrv.Controls.Add($script:btnRefreshDrv)
        $flowDrv.Controls.Add($script:lblDrvCount)
        New-FullWidthRow -Control $flowDrv -Table $drvCard.ContentTable -RowIndex 1

        return @{
            lbImages      = $script:lbImages
            lbDrivers     = $script:lbDrivers
            btnRefreshImg = $script:btnRefreshImg
            btnRefreshDrv = $script:btnRefreshDrv
            lblImgCount   = $script:lblImgCount
            lblDrvCount   = $script:lblDrvCount
        }
    }
}

# - PAGE 3: Configure --------------------
$pageConfigure = @{
    Name  = "configure"
    Title = "Configure"
    BuildContent = {
        param($parent)

        # Deployment options card
        $cfgCard = New-CardPanel -Title "DEPLOYMENT OPTIONS" -Parent $parent -Height 170
        $t = $cfgCard.ContentTable

        $script:txtDisk = New-StyledTextBox -Text $DefaultDisk.ToString()
        New-FormRow -Label "Target disk #" -Control $script:txtDisk -Table $t -RowIndex 0

        $script:txtIndex = New-StyledTextBox -Text $DefaultIndex.ToString()
        New-FormRow -Label "Image index" -Control $script:txtIndex -Table $t -RowIndex 1

        $script:txtReboot = New-StyledTextBox -Text $RebootSecs.ToString()
        New-FormRow -Label "Reboot delay (s)" -Control $script:txtReboot -Table $t -RowIndex 2

        New-SpacerPanel -Height 6 | ForEach-Object { $parent.Controls.Add($_) }

        # OS configuration card
        $osCard = New-CardPanel -Title "OS CONFIGURATION" -Parent $parent -Height 250
        $to = $osCard.ContentTable

        $script:txtNameTemplate = New-StyledTextBox -Text $ComputerNameTemplate
        New-FormRow -Label "Computer name" -Control $script:txtNameTemplate -Table $to -RowIndex 0

        $script:txtDomain = New-StyledTextBox -Text $DomainName
        New-FormRow -Label "Domain" -Control $script:txtDomain -Table $to -RowIndex 1

        $script:txtOU = New-StyledTextBox -Text $DomainOU
        New-FormRow -Label "OU path" -Control $script:txtOU -Table $to -RowIndex 2

        $script:txtProductKey = New-StyledTextBox -Text $ProductKey
        New-FormRow -Label "Product key" -Control $script:txtProductKey -Table $to -RowIndex 3

        $script:txtTimezone = New-StyledTextBox -Text $Timezone
        New-FormRow -Label "Timezone" -Control $script:txtTimezone -Table $to -RowIndex 4

        $script:lblOsNote = New-StyledLabel `
            -Text "  Name: use %SERVICETAG%, %MODEL%, %VENDOR%.  Domain creds = share creds." `
            -FontName "small" -ColorName "TextMuted"
        New-FullWidthRow -Control $script:lblOsNote -Table $to -RowIndex 5

        New-SpacerPanel -Height 6 | ForEach-Object { $parent.Controls.Add($_) }

        # WiFi + Connectivity card
        $wifiCard = New-CardPanel -Title "WIFI (OPTIONAL)" -Parent $parent -Height 140
        $tw = $wifiCard.ContentTable

        $script:txtWifiSSID = New-StyledTextBox -Text $WifiSSID
        New-FormRow -Label "SSID" -Control $script:txtWifiSSID -Table $tw -RowIndex 0

        $script:txtWifiPass = New-StyledTextBox -Password -Text $WifiPassword
        New-FormRow -Label "Password" -Control $script:txtWifiPass -Table $tw -RowIndex 1

        New-SpacerPanel -Height 6 | ForEach-Object { $parent.Controls.Add($_) }

        # Post-setup apps card (read-only display from config)
        $appsText = "(No apps configured in DeployConfig.json)"
        if ($AppsConfig -and $AppsConfig.Packages -and @($AppsConfig.Packages).Count -gt 0) {
            $appLines = @("$(@($AppsConfig.Packages).Count) app(s) will install after Windows setup:")
            $num = 0
            foreach ($pkg in @($AppsConfig.Packages)) {
                $num++
                $appLines += "  $num. $($pkg.Name)"
            }
            $appLines += ""
            $appLines += "Source: $(if ($AppsConfig.SharePath) { $AppsConfig.SharePath } else { '(uses deploy share)' })"
            $appsText = $appLines -join "`r`n"
        }

        $appsCard = New-CardPanel -Title "POST-SETUP APPS" -Parent $parent -Height 140
        $script:lblApps = New-StyledLabel -Text $appsText -FontName "body" -ColorName "TextDim"
        $script:lblApps.AutoSize = $false
        $script:lblApps.Dock = [System.Windows.Forms.DockStyle]::Fill
        $script:lblApps.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
        New-FullWidthRow -Control $script:lblApps -Table $appsCard.ContentTable -RowIndex 0

        New-SpacerPanel -Height 6 | ForEach-Object { $parent.Controls.Add($_) }

        # Summary card
        $sumCard = New-CardPanel -Title "DEPLOYMENT SUMMARY" -Parent $parent -Height 340
        $script:lblSummary = New-StyledLabel -Text "Select an image and driver pack first." -FontName "body" -ColorName "TextDim"
        $script:lblSummary.AutoSize = $false
        $script:lblSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
        $script:lblSummary.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
        New-FullWidthRow -Control $script:lblSummary -Table $sumCard.ContentTable -RowIndex 0

        return @{
            txtDisk         = $script:txtDisk
            txtIndex        = $script:txtIndex
            txtReboot       = $script:txtReboot
            txtNameTemplate = $script:txtNameTemplate
            txtDomain       = $script:txtDomain
            txtOU           = $script:txtOU
            txtProductKey   = $script:txtProductKey
            txtTimezone     = $script:txtTimezone
            txtWifiSSID     = $script:txtWifiSSID
            txtWifiPass     = $script:txtWifiPass
            lblApps         = $script:lblApps
            lblSummary      = $script:lblSummary
        }
    }
}

# - PAGE 4: Deploy ---------------------─
$pageDeploy = @{
    Name  = "deploy"
    Title = "Deploy"
    BuildContent = {
        param($parent)

        # Progress card
        $progCard = New-CardPanel -Title "DEPLOYMENT PROGRESS" -Parent $parent -Height 130
        $script:progressBar = New-GradientProgressBar -Height 18
        New-FullWidthRow -Control $script:progressBar -Table $progCard.ContentTable -RowIndex 0

        $script:lblProgressStatus = New-StyledLabel -Text "  Waiting to start..." -FontName "body" -ColorName "TextDim"
        New-FullWidthRow -Control $script:lblProgressStatus -Table $progCard.ContentTable -RowIndex 1

        New-SpacerPanel -Height 20 | ForEach-Object { $parent.Controls.Add($_) }

        # Log viewer card (fill remaining space)
        $logCard = New-CardPanel -Title "DEPLOYMENT LOG" -Parent $parent -Fill
        $script:rtbLog = New-StyledRichTextBox -ReadOnly
        $script:rtbLog.Dock = [System.Windows.Forms.DockStyle]::Fill
        New-FullWidthRow -Control $script:rtbLog -Table $logCard.ContentTable -RowIndex 0

        return @{
            progressBar      = $script:progressBar
            lblProgressStatus = $script:lblProgressStatus
            rtbLog           = $script:rtbLog
        }
    }
}

# ============================================================
#  CREATE PAGE MANAGER
# ============================================================
$pm = New-PageManager -ContentPanel $shell.ContentArea `
    -SidebarPanel $shell.SidebarSteps `
    -Pages @($pageConnect, $pageSelect, $pageConfigure, $pageDeploy)

# ============================================================
#  ACTION BAR — Navigation + Deploy
# ============================================================
$script:btnDeploy = New-RoundedButton -Text "Deploy" -Width 160 -Height 40 -Large
$script:btnDeploy.Enabled = $false
$script:btnDeploy.Dock = [System.Windows.Forms.DockStyle]::Right
$shell.ActionBar.Controls.Add($script:btnDeploy)

$script:btnNext = New-RoundedButton -Text "Next" -Width 120 -Height 40 -Large
$script:btnNext.Dock = [System.Windows.Forms.DockStyle]::Right
$shell.ActionBar.Controls.Add($script:btnNext)

$script:btnBack = New-RoundedButton -Text "Back" -Width 120 -Height 40 -Large -Secondary
$script:btnBack.Dock = [System.Windows.Forms.DockStyle]::Right
$shell.ActionBar.Controls.Add($script:btnBack)

$script:lblActionStatus = New-StyledLabel -Text "Complete all steps to enable deployment" -FontName "small" -ColorName "TextDim"
$script:lblActionStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:lblActionStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$shell.ActionBar.Controls.Add($script:lblActionStatus)

# ============================================================
#  HELPER FUNCTIONS
# ============================================================
function Refresh-ImageList {
    $script:lbImages.Items.Clear()
    $imagesPath = "$DriveLetter\$ImagesFolder"
    $images = Get-AvailableImages -ImagesPath $imagesPath
    if ($images -and @($images).Count -gt 0) {
        foreach ($img in $images) {
            $script:lbImages.Items.Add("$($img.Name)  [$($img.SizeGB) GB]  $($img.LastWriteTime.ToString('yyyy-MM-dd'))") | Out-Null
        }
        $script:lbImages.Tag = $images
        $script:lblImgCount.Text = "  $(@($images).Count) image(s) found"
        $script:lblImgCount.ForeColor = Get-ThemeColor "Success"
        Update-Log "Found $(@($images).Count) WIM image(s)"
    } else {
        $script:lblImgCount.Text = "  No images found in $imagesPath"
        $script:lblImgCount.ForeColor = Get-ThemeColor "Warning"
        Update-Log "WARNING: No images at $imagesPath"
    }
}

function Refresh-DriverList {
    $script:lbDrivers.Items.Clear()
    $driversPath = "$DriveLetter\$DriversFolder"
    $packs = Get-AvailableDriverPacks -DriversPath $driversPath
    if ($packs -and @($packs).Count -gt 0) {
        foreach ($drv in $packs) {
            $script:lbDrivers.Items.Add($drv.DisplayName) | Out-Null
        }
        $script:lbDrivers.Tag = $packs
        $script:lblDrvCount.Text = "  $(@($packs).Count) driver pack(s) found"
        $script:lblDrvCount.ForeColor = Get-ThemeColor "Success"
        Update-Log "Found $(@($packs).Count) driver pack(s)"

        # Auto-select matching driver pack for detected hardware
        if ($script:ModelInfo) {
            try {
                $modelKey = $script:ModelInfo.ModelKey
                $modelRaw = $script:ModelInfo.Model
                $bestIdx   = -1
                $bestScore = 0
                for ($i = 0; $i -lt @($packs).Count; $i++) {
                    $packItem = @($packs)[$i]
                    $info  = Get-DriverPackInfo (Get-Item $packItem.FullName -ErrorAction SilentlyContinue)
                    if ($info) {
                        $score = Get-PackMatchScore -Info $info -ModelKey $modelKey -ModelRaw $modelRaw
                        if ($score -ge 3 -and $score -gt $bestScore) {
                            $bestScore = $score
                            $bestIdx   = $i
                        }
                    }
                }
                if ($bestIdx -ge 0) {
                    $script:lbDrivers.SelectedIndex = $bestIdx
                    Update-Log "Auto-selected driver: $(@($packs)[$bestIdx].Name) (score $bestScore)"
                }
            } catch {
                Update-Log "WARNING: Driver auto-select failed: $_"
            }
        }
    } else {
        $script:lblDrvCount.Text = "  No driver packs found in $driversPath"
        $script:lblDrvCount.ForeColor = Get-ThemeColor "Warning"
        Update-Log "WARNING: No driver packs at $driversPath"
    }
}

function Update-Summary {
    $imgText = if ($script:lbImages.SelectedIndex -ge 0) {
        $script:lbImages.SelectedItem.ToString()
    } else { "(none selected)" }

    $drvText = if ($script:lbDrivers.SelectedIndex -ge 0) {
        $script:lbDrivers.SelectedItem.ToString()
    } else { "(none selected)" }

    $diskNum  = $script:txtDisk.Text
    $imgIndex = $script:txtIndex.Text
    $rebootS  = $script:txtReboot.Text

    $hw = if ($script:ModelInfo) { "$($script:ModelInfo.Manufacturer) $($script:ModelInfo.Model)" } else { "Unknown" }

    $nameT    = $script:txtNameTemplate.Text
    $domain   = $script:txtDomain.Text
    $ou       = $script:txtOU.Text
    $key      = if ($script:txtProductKey.Text) { "***configured***" } else { "(none)" }
    $tz       = $script:txtTimezone.Text
    $wifi     = if ($script:txtWifiSSID.Text) { $script:txtWifiSSID.Text } else { "(none)" }
    $appCount = if ($AppsConfig -and $AppsConfig.Packages) { @($AppsConfig.Packages).Count } else { 0 }

    $script:lblSummary.Text = @"
Machine:        $hw
Image:          $imgText
Driver Pack:    $drvText
Target Disk:    $diskNum  |  Index: $imgIndex  |  Reboot: ${rebootS}s
Computer Name:  $(if ($nameT) { $nameT } else { "(auto)" })
Domain:         $(if ($domain) { $domain } else { "(none)" })
OU:             $(if ($ou) { $ou } else { "(default)" })
Product Key:    $key
Timezone:       $tz
WiFi:           $wifi
Apps:           $appCount app(s) queued
"@

    # Enable deploy if image + drivers selected + share connected
    $ready = $script:ShareMapped -and
             ($script:lbImages.SelectedIndex -ge 0) -and
             ($script:lbDrivers.SelectedIndex -ge 0)
    $script:btnDeploy.Enabled = $ready
    if ($ready) {
        $script:lblActionStatus.Text = "Ready to deploy"
        $script:lblActionStatus.ForeColor = Get-ThemeColor "Success"
    } else {
        $script:lblActionStatus.Text = "Complete all steps to enable deployment"
        $script:lblActionStatus.ForeColor = Get-ThemeColor "TextDim"
    }
}

function Update-NavigationState {
    $idx = $pm.ActiveIndex
    $hasSelections = ($script:lbImages.SelectedIndex -ge 0) -and ($script:lbDrivers.SelectedIndex -ge 0)

    $script:btnBack.Enabled = ($idx -gt 0) -and (-not $script:DeployRunning)

    # Deploy button is only visible on deploy page.
    $script:btnDeploy.Visible = ($idx -eq 3)
    $script:btnDeploy.Enabled = ($idx -eq 3) -and $script:btnDeploy.Enabled

    # Next button is hidden on deploy page.
    $script:btnNext.Visible = ($idx -lt 3)
    $script:btnNext.Enabled = $false

    switch ($idx) {
        0 { $script:btnNext.Enabled = $script:ShareMapped }
        1 { $script:btnNext.Enabled = $script:ShareMapped -and $hasSelections }
        2 { $script:btnNext.Enabled = $hasSelections -and (-not $script:DeployRunning) }
    }
}

# ============================================================
#  EVENT HANDLERS
# ============================================================

# - Form Load: detect hardware ---------------─
$form.Add_Shown({
    try {
        $script:ModelInfo = Get-HardwareInfo
        $script:lblHWInfo.Text = "$($script:ModelInfo.Manufacturer) $($script:ModelInfo.Model)  |  S/N: $($script:ModelInfo.ServiceTag)"
        Update-Log "Machine: $($script:ModelInfo.Manufacturer) $($script:ModelInfo.Model) [$($script:ModelInfo.ServiceTag)]"
    } catch {
        $script:lblHWInfo.Text = "Hardware detection failed"
        Update-Log "WARNING: Hardware detection failed: $_"
    }
})

# - Connect button ---------------------─
$script:btnConnect.Add_Click({
    if (-not $script:txtUser.Text.Trim() -or -not $script:txtPass.Text) {
        $script:lblConnStatus.Text = "  Enter credentials"
        $script:lblConnStatus.ForeColor = Get-ThemeColor "Warning"
        return
    }

    $script:btnConnect.Enabled = $false
    $script:lblConnStatus.Text = "  Connecting..."
    $script:lblConnStatus.ForeColor = Get-ThemeColor "TextDim"

    $secPass     = $script:txtPass.Text | ConvertTo-SecureString -AsPlainText -Force
    $shareTarget = $script:txtShare.Text.Trim()

    $result = Connect-NetworkShare -SharePath $shareTarget `
                  -Username $script:txtUser.Text.Trim() `
                  -Password $secPass `
                  -DriveLetter $DriveLetter

    if ($result.Success) {
        $script:ShareMapped = $true
        $script:ShareResult = $result
        $script:lblConnStatus.Text = "  Connected ($DriveLetter)"
        $script:lblConnStatus.ForeColor = Get-ThemeColor "Success"
        Update-Log "Share mapped: $DriveLetter -> $shareTarget"

        $shell.StatusLeft.Text = "Deploy Tool  |  Connected to $shareTarget"

        # Mark connect page complete and advance
        Set-PageComplete -Manager $pm -Index 0
        Advance-ToNextPage -Manager $pm

        # Auto-populate image and driver lists
        Refresh-ImageList
        Refresh-DriverList
        Update-NavigationState
    } else {
        $script:ShareMapped = $false
        $script:lblConnStatus.Text = "  Connection failed"
        $script:lblConnStatus.ForeColor = Get-ThemeColor "Error"
        Update-Log "ERROR: Share connection failed: $($result.ErrorMessage)"
        $script:btnConnect.Enabled = $true
        Update-NavigationState
    }
})

# - Back button -----------------------
$script:btnBack.Add_Click({
    if ($script:DeployRunning) { return }
    $prev = $pm.ActiveIndex - 1
    if ($prev -ge 0) {
        Set-ActivePage -Manager $pm -Index $prev
    }
})

# - Refresh buttons ---------------------
$script:btnRefreshImg.Add_Click({
    if ($script:ShareMapped) { Refresh-ImageList }
})

$script:btnRefreshDrv.Add_Click({
    if ($script:ShareMapped) { Refresh-DriverList }
})

# - List selection changes -----------------─
$script:lbImages.Add_SelectedIndexChanged({
    if ($script:lbImages.SelectedIndex -ge 0) {
        $images = $script:lbImages.Tag
        if ($images) {
            $script:SelectedImage = @($images)[$script:lbImages.SelectedIndex]
            Update-Log "Image selected: $($script:SelectedImage.Name)"
        }
        Update-Summary
        # Mark select page complete and advance to Configure if both are chosen
        if ($script:lbDrivers.SelectedIndex -ge 0) {
            Set-PageComplete -Manager $pm -Index 1
            Advance-ToNextPage -Manager $pm
        }
        Update-NavigationState
    }
})

$script:lbDrivers.Add_SelectedIndexChanged({
    if ($script:lbDrivers.SelectedIndex -ge 0) {
        $packs = $script:lbDrivers.Tag
        if ($packs) {
            $script:SelectedDriver = @($packs)[$script:lbDrivers.SelectedIndex]
            Update-Log "Driver pack selected: $($script:SelectedDriver.Name)"
        }
        Update-Summary
        # Mark select page complete and advance to Configure if both are chosen
        if ($script:lbImages.SelectedIndex -ge 0) {
            Set-PageComplete -Manager $pm -Index 1
            Advance-ToNextPage -Manager $pm
        }
        Update-NavigationState
    }
})

# - Config field changes update summary -----------
$script:txtDisk.Add_TextChanged({ Update-Summary })
$script:txtIndex.Add_TextChanged({ Update-Summary })
$script:txtReboot.Add_TextChanged({ Update-Summary })
$script:txtNameTemplate.Add_TextChanged({ Update-Summary })
$script:txtDomain.Add_TextChanged({ Update-Summary })
$script:txtOU.Add_TextChanged({ Update-Summary })
$script:txtProductKey.Add_TextChanged({ Update-Summary })
$script:txtTimezone.Add_TextChanged({ Update-Summary })
$script:txtWifiSSID.Add_TextChanged({ Update-Summary })

# - Wizard navigation buttons ----------------
$script:btnBack.Add_Click({
    if ($script:DeployRunning) { return }
    $prev = $pm.ActiveIndex - 1
    if ($prev -ge 0) {
        Set-ActivePage -Manager $pm -Index $prev
    }
})

$script:btnNext.Add_Click({
    if ($script:DeployRunning) { return }

    switch ($pm.ActiveIndex) {
        0 {
            if ($script:ShareMapped) {
                Set-PageComplete -Manager $pm -Index 0
                Set-ActivePage -Manager $pm -Index 1
            }
        }
        1 {
            if (($script:lbImages.SelectedIndex -ge 0) -and ($script:lbDrivers.SelectedIndex -ge 0)) {
                Set-PageComplete -Manager $pm -Index 1
                Set-ActivePage -Manager $pm -Index 2
            }
        }
        2 {
            Set-PageComplete -Manager $pm -Index 2
            Set-ActivePage -Manager $pm -Index 3
        }
    }
})

# - Navigate to configure page marks it as visited -----─
# (Auto-complete configure page when user visits it and has selections)

# - Deploy button ----------------------
$script:btnDeploy.Add_Click({
    if ($script:DeployRunning) { return }
    if (-not $script:SelectedImage -or -not $script:SelectedDriver) { return }

    $diskNum  = [int]$script:txtDisk.Text
    $imgIndex = [int]$script:txtIndex.Text

    # Final confirmation
    $confirmMsg = @"
CONFIRM DEPLOYMENT

Machine:     $($script:ModelInfo.Model)  [S/N: $($script:ModelInfo.ServiceTag)]
Image:       $($script:SelectedImage.Name)  [$($script:SelectedImage.SizeGB) GB]
Driver Pack: $($script:SelectedDriver.Name)
Target Disk: $diskNum
Image Index: $imgIndex

WARNING: ALL DATA ON DISK $diskNum WILL BE DESTROYED.

This process may take 20-45 minutes.
Do NOT interrupt power during deployment.

Proceed?
"@

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        $confirmMsg, "Confirm Deployment",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne "Yes") { return }

    # Switch to deploy page
    Set-PageComplete -Manager $pm -Index 2
    Set-ActivePage -Manager $pm -Index 3
    Update-NavigationState

    $script:DeployRunning  = $true
    $pm.Locked = $true
    $script:btnDeploy.Enabled = $false
    $script:btnBack.Enabled   = $false
    $script:btnNext.Enabled   = $false
    $script:lblActionStatus.Text = "Deployment in progress - do not interrupt..."
    $script:lblActionStatus.ForeColor = Get-ThemeColor "Warning"
    $shell.StatusLeft.Text = "Deploy Tool  |  Deploying..."

    Set-Progress -Bar $script:progressBar -Value 0
    $script:lblProgressStatus.Text = "  Starting deployment..."
    $script:lblProgressStatus.ForeColor = Get-ThemeColor "Text"
    Update-Log "=== DEPLOYMENT STARTED ==="

    # Build runtime config merging file defaults + GUI edits
    $runtimeConfig = @{
        Deployment = @{
            ComputerNameTemplate = $script:txtNameTemplate.Text.Trim()
            DomainName           = $script:txtDomain.Text.Trim()
            DomainOU             = $script:txtOU.Text.Trim()
            ProductKey           = $script:txtProductKey.Text.Trim()
            Timezone             = $script:txtTimezone.Text.Trim()
            InputLocale          = $InputLocale
            SystemLocale         = $SystemLocale
            UserLocale           = $UserLocale
            WifiSSID             = $script:txtWifiSSID.Text.Trim()
            WifiPassword         = $script:txtWifiPass.Text
        }
        App = @{
            OrgName = $OrgName
        }
        Apps = $AppsConfig
        # Domain join uses the same creds from the Connect page
        DomainCredentials = @{
            Username = $script:txtUser.Text.Trim()
            Password = $script:txtPass.Text
        }
    }

    # Build deployment params
    $deployParams = @{
        ImagePath     = $script:SelectedImage.FullName
        DriverPackPath = $script:SelectedDriver.FullName
        DriverPackIsZip = $script:SelectedDriver.IsZip
        ImageIndex    = $imgIndex
        TargetDisk    = $diskNum
        ConfirmWipe   = $true
        DeployConfig  = $runtimeConfig
    }

    # Progress callback — invoked from background thread via form.Invoke
    # Capture all control references directly so the closure is self-contained.
    $cbForm     = $form
    $cbProgress = $script:progressBar
    $cbStatus   = $script:lblProgressStatus
    $cbLog      = $script:rtbLog
    $progressCallback = {
        param([int]$pct, [string]$status)
        $cbForm.Invoke([Action]{
            if ($pct -ge 0) {
                $cbProgress.Tag = [Math]::Max(0, [Math]::Min(100, $pct))
                $cbProgress.Invalidate()
            }
            $cbStatus.Text = "  $status"
            $timestamp = Get-Date -Format "HH:mm:ss"
            $cbLog.AppendText("[$timestamp] $status`r`n")
            $cbLog.ScrollToCaret()
        })
    }.GetNewClosure()

    # Build completion callbacks as closures in the main scope where
    # control references ($cbProgress, $cbStatus, etc.) are real variables.
    # These closures are self-contained and safe to invoke from the runspace.
    $cbBtnDeploy    = $script:btnDeploy
    $cbActionStatus = $script:lblActionStatus
    $cbStatusLeft   = $shell.StatusLeft
    $cbRebootSecs   = $RebootSecs

    $onComplete = {
        param([bool]$success, [string]$detail)
        if ($success) {
            $cbProgress.Tag = 100; $cbProgress.Invalidate()
            $cbStatus.Text = "  Deployment successful! Rebooting..."
            $cbStatus.ForeColor = [System.Drawing.Color]::FromArgb(19, 186, 111)
            $cbActionStatus.Text = "Deployment complete"
            $cbActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(19, 186, 111)
            $cbStatusLeft.Text = "Deploy Tool  |  Complete"
            $cbLog.AppendText("`r`n=== DEPLOYMENT COMPLETE ===`r`nElapsed: $detail`r`n")
            $cbLog.ScrollToCaret()

            # Reboot immediately
            wpeutil reboot
        } else {
            $cbProgress.Tag = 0; $cbProgress.Invalidate()
            $cbStatus.Text = "  DEPLOYMENT FAILED: $detail"
            $cbStatus.ForeColor = [System.Drawing.Color]::FromArgb(232, 17, 35)
            $cbActionStatus.Text = "Deployment failed - check log"
            $cbActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(232, 17, 35)
            $cbStatusLeft.Text = "Deploy Tool  |  Failed"
            $cbBtnDeploy.Enabled = $true
            $cbLog.AppendText("`r`n=== DEPLOYMENT FAILED ===`r`n$detail`r`n")
            $cbLog.ScrollToCaret()
        }
        $script:DeployRunning = $false
    }.GetNewClosure()

    # Run deployment in a background runspace to keep UI responsive
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('ScriptRoot',        $ScriptRoot)
    $runspace.SessionStateProxy.SetVariable('deployParams',      $deployParams)
    $runspace.SessionStateProxy.SetVariable('progressCallback',  $progressCallback)
    $runspace.SessionStateProxy.SetVariable('form',              $form)
    $runspace.SessionStateProxy.SetVariable('onComplete',        $onComplete)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        . "$ScriptRoot\Logging\Write-DeployLog.ps1"
        . "$ScriptRoot\Core\Map-NetworkShare.ps1"
        . "$ScriptRoot\Core\Invoke-Deployment.ps1"
        . "$ScriptRoot\Hardware\Get-HardwareModel.ps1"
        . "$ScriptRoot\Core\Expand-DriverPack.ps1"
        . "$ScriptRoot\Core\Inject-Drivers.ps1"
        . "$ScriptRoot\Core\Apply-Image.ps1"

        $deployParams.ProgressCallback = $progressCallback
        $result = Invoke-Deployment @deployParams

        if ($result.Success) {
            $detail = $result.ElapsedTime.ToString('mm\:ss')
            $form.Invoke([Action]{ & $onComplete $true $detail })
        } else {
            $detail = $result.ErrorMessage
            $form.Invoke([Action]{ & $onComplete $false $detail })
        }
    })

    [void]$ps.BeginInvoke()
})

$pm.OnPageChanged = {
    param($manager, $newIndex)
    if ($newIndex -eq 3) {
        Update-Summary
    }
    Update-NavigationState
}
Update-NavigationState

# - Keyboard shortcuts -------------------─
$form.Add_KeyDown({
    if ($_.KeyCode -eq "F5" -and $script:ShareMapped) {
        Refresh-ImageList
        Refresh-DriverList
    }
    if ($_.KeyCode -eq "Escape" -and -not $script:DeployRunning) {
        $q = [System.Windows.Forms.MessageBox]::Show(
            "Exit to WinPE command prompt?", "Exit",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($q -eq "Yes") { $form.Close() }
    }
})
$form.KeyPreview = $true

# ============================================================
#  LAUNCH
# ============================================================
Update-Log "DynamicPxE Deploy Tool started - $AppVersion"
Update-Log "Target share: $ShareRoot ($DriveLetter)"
[System.Windows.Forms.Application]::Run($form)
