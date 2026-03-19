# ============================================================
#  Start-DeployGUI.ps1
#  PowerShell WinForms GUI for WinPE Dell Deployment
#  Launched by startnet.cmd at WinPE boot
# ============================================================

#Requires -Version 5.1

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

#  Load .NET assemblies for WinForms 
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

#  Script paths
$ScriptRoot = "X:\Deploy\Scripts"
$ConfigRoot = "X:\Deploy\Config"

#  Load DeployConfig.json
$ConfigFile = "$ConfigRoot\DeployConfig.json"
if (Test-Path $ConfigFile) {
    try {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    } catch {
        $Config = $null
    }
} else {
    $Config = $null
}

#  Apply config values - direct property access, no helper function
$ShareRoot     = "\\server\share"
$DriveLetter   = "Z:"
$ImagesFolder  = "Images"
$DriversFolder = "Drivers"
$AppTitle      = "Dell Image Assist"
$AppVersion    = "1.0"
$OrgName       = ""
$BuildLabel    = "WinPE 11  ADK 26100"
$DomainPrefix  = "DOMAIN\"
$DefaultIndex  = 2
$DefaultDisk   = 0
$RebootSecs    = 15
$accentR       = 0
$accentG       = 120
$accentB       = 212

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
    try { $DefaultIndex = [int]$Config.Deployment.DefaultImageIndex }                                               catch {}
    try { $DefaultDisk  = [int]$Config.Deployment.DefaultTargetDisk }                                               catch {}
    try { $RebootSecs   = [int]$Config.Deployment.AutoRebootSeconds }                                               catch {}
    try { $accentR      = [int]$Config.Branding.AccentColorR }                                                      catch {}
    try { $accentG      = [int]$Config.Branding.AccentColorG }                                                      catch {}
    try { $accentB      = [int]$Config.Branding.AccentColorB }                                                      catch {}
}

$ImagesPath  = "$DriveLetter\$ImagesFolder"
$DriversPath = "$DriveLetter\$DriversFolder"

#  Dot-source modules
. "$ScriptRoot\Logging\Write-DeployLog.ps1"
. "$ScriptRoot\Core\Map-NetworkShare.ps1"
. "$ScriptRoot\Core\Apply-Image.ps1"
. "$ScriptRoot\Core\Inject-Drivers.ps1"
. "$ScriptRoot\Core\Invoke-Deployment.ps1"
. "$ScriptRoot\Dell\Get-DellModel.ps1"
. "$ScriptRoot\Dell\Get-DellDriverPack.ps1"

Initialize-Log
Write-LogInfo -Msg "GUI starting..." -Comp "GUI"

#  Color palette
$clrBackground  = [System.Drawing.Color]::FromArgb(18,  18,  18)
$clrSurface     = [System.Drawing.Color]::FromArgb(30,  30,  30)
$clrSurface2    = [System.Drawing.Color]::FromArgb(40,  40,  40)
$clrAccent      = [System.Drawing.Color]::FromArgb($accentR, $accentG, $accentB)
$clrAccentHover = [System.Drawing.Color]::FromArgb(
    [Math]::Min(255, $accentR + 30),
    [Math]::Min(255, $accentG + 30),
    [Math]::Min(255, $accentB + 43))
$clrSuccess     = [System.Drawing.Color]::FromArgb(19,  186, 111)
$clrWarning     = [System.Drawing.Color]::FromArgb(255, 185, 0)
$clrError       = [System.Drawing.Color]::FromArgb(232, 17,  35)
$clrText        = [System.Drawing.Color]::FromArgb(240, 240, 240)
$clrTextDim     = [System.Drawing.Color]::FromArgb(160, 160, 160)
$clrBorder      = [System.Drawing.Color]::FromArgb(60,  60,  60)

#  Fonts 
$fontUI     = New-Object System.Drawing.Font("Segoe UI", 9)
$fontBold   = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$fontLarge  = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$fontTitle  = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$fontMono   = New-Object System.Drawing.Font("Consolas", 8)
$fontSmall  = New-Object System.Drawing.Font("Segoe UI", 8)

#  State 
$script:ShareMapped     = $false
$script:ModelInfo       = $null
$script:SuggestedDriver = $null
$script:DeployRunning   = $false

# ============================================================
#  HELPER FUNCTIONS
# ============================================================

function New-Label {
    param($Text, $X, $Y, $W, $H, $Font = $fontUI, $Color = $clrText, $Align = "MiddleLeft")
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Text
    $lbl.Location  = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size      = New-Object System.Drawing.Size($W, $H)
    $lbl.Font      = $Font
    $lbl.ForeColor = $Color
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::$Align
    return $lbl
}

function New-StyledButton {
    param($Text, $X, $Y, $W = 160, $H = 34, $AccentColor = $clrAccent)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = $Text
    $btn.Location  = New-Object System.Drawing.Point($X, $Y)
    $btn.Size      = New-Object System.Drawing.Size($W, $H)
    $btn.Font      = $fontBold
    $btn.ForeColor = $clrText
    $btn.BackColor = $AccentColor
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    # Use GetNewClosure() to capture $AccentColor at function call time
    # Without this, $AccentColor is null when the event fires later
    $capturedAccent = $AccentColor
    $btn.Add_MouseEnter({ $this.BackColor = $clrAccentHover })
    $btn.Add_MouseLeave({ $this.BackColor = $capturedAccent }.GetNewClosure())
    return $btn
}

function New-Panel {
    param($X, $Y, $W, $H, $BgColor = $clrSurface)
    $p = New-Object System.Windows.Forms.Panel
    $p.Location  = New-Object System.Drawing.Point($X, $Y)
    $p.Size      = New-Object System.Drawing.Size($W, $H)
    $p.BackColor = $BgColor
    return $p
}

function New-TextBox {
    param($X, $Y, $W, $H = 26, $Password = $false, $Text = "")
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location    = New-Object System.Drawing.Point($X, $Y)
    $tb.Size        = New-Object System.Drawing.Size($W, $H)
    $tb.Font        = $fontUI
    $tb.ForeColor   = $clrText
    $tb.BackColor   = $clrSurface2
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tb.Text        = $Text
    if ($Password) { $tb.PasswordChar = [char]0x2022 }
    return $tb
}

function New-ListBox {
    param($X, $Y, $W, $H)
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location          = New-Object System.Drawing.Point($X, $Y)
    $lb.Size              = New-Object System.Drawing.Size($W, $H)
    $lb.Font              = $fontUI
    $lb.ForeColor         = $clrText
    $lb.BackColor         = $clrSurface2
    $lb.BorderStyle       = [System.Windows.Forms.BorderStyle]::FixedSingle
    $lb.SelectionMode     = "One"
    $lb.IntegralHeight    = $false
    return $lb
}

function Set-StatusBadge {
    param($Label, $Text, $Color = $clrTextDim)
    $Label.Text      = $Text
    $Label.ForeColor = $Color
    $Label.Refresh()
}

function Update-Log {
    param([string]$Message)
    if ($script:txtLog -and -not $script:txtLog.IsDisposed) {
        # Check if handle is created before using Invoke
        # In WinPE the form may not have a handle yet on first call
        if ($script:txtLog.IsHandleCreated) {
            $script:txtLog.Invoke([Action]{
                $script:txtLog.AppendText("$Message`r`n")
                $script:txtLog.ScrollToCaret()
            })
        } else {
            # Direct update before handle exists - safe on single UI thread
            $script:txtLog.AppendText("$Message`r`n")
        }
    }
}

# ============================================================
#  MAIN FORM
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "$AppTitle - WinPE Deployment"
$form.StartPosition   = "CenterScreen"
$form.BackColor       = $clrBackground
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox     = $true
$form.MinimizeBox     = $false
$form.Font            = $fontUI
$form.AutoScroll      = $true
$form.AutoScrollMinSize = New-Object System.Drawing.Size(780, 570)

# Load icon from config if specified
if ($Config.Branding.IconPath -and (Test-Path $Config.Branding.IconPath)) {
    try {
        $form.Icon = New-Object System.Drawing.Icon($Config.Branding.IconPath)
    } catch { }
}

# Auto-detect screen size and size form accordingly
# Leave 40px for taskbar at bottom, 16px for window chrome on sides
$screen     = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formWidth  = [Math]::Max(780, $screen.Width  - 16)
$formHeight = [Math]::Max(570, $screen.Height - 40)
$form.Size  = New-Object System.Drawing.Size($formWidth, $formHeight)
$form.MinimumSize = New-Object System.Drawing.Size(780, 570)

# ── Two-column landscape layout ────────────────────────────────
# Left column: hardware, network, images, drivers (~58% width)
# Right column: logo, summary, progress, deploy, log (~40% width)
# Gap between columns: 6px, edge padding: 6px

$pad    = 6
$gap    = 6
$titleH = 44
$statusH = 28
$bodyH  = $formHeight - $titleH - $statusH

# Logo size - sits in top right of right column
$logoSize = 200

# Column widths
$leftW  = [int]($formWidth * 0.57) - $pad
$rightW = $formWidth - $leftW - ($pad * 2) - $gap - 18
$rightX = $pad + $leftW + $gap

# Inner widths with padding
$lInner = $leftW - 8
$rInner = $rightW - 8

# Left column Y positions - stacked sections
$hwH    = 52
$netH   = 118
$imgH   = [int]($bodyH * 0.28)
$drvH   = [int]($bodyH * 0.28)
$leftRemainder = $bodyH - $hwH - $netH - $imgH - $drvH - ($gap * 3)

$hwY    = $titleH + $gap
$netY   = $hwY  + $hwH  + $gap
$imgY   = $netY + $netH + $gap
$drvY   = $imgY + $imgH + $gap

# Right column Y positions
$sumH   = 178
$progH  = 68
$actH   = 52
$logH   = [Math]::Max(60, $bodyH - $logoSize - $sumH - $progH - $actH - ($gap * 5) - $statusH)
$logoY  = $titleH
$sumY   = $logoY + $logoSize + $gap
$progY2 = $sumY  + $sumH + $gap
$actY2  = $progY2 + $progH + $gap
$logY2  = $actY2  + $actH + $gap

# ── Title bar ──────────────────────────────────────────────────
$pnlTitle = New-Panel 0 0 $formWidth $titleH $clrSurface
$pnlTitle.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right"
$lblTitle = New-Label "  $AppTitle" 8 0 ([int]($formWidth*0.55)) $titleH $fontBold $clrText "MiddleLeft"
$lblBuild = New-Label "$BuildLabel" 0 0 ($formWidth - $logoSize - 12) $titleH $fontSmall $clrTextDim "MiddleRight"
$lblBuild.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Right"
$pnlTitle.Controls.AddRange(@($lblTitle, $lblBuild))
$form.Controls.Add($pnlTitle)

# ── Logo - top right, square ────────────────────────────────────
if ($Config -and $Config.Branding.LogoPath -and (Test-Path $Config.Branding.LogoPath)) {
    try {
        $picLogo          = New-Object System.Windows.Forms.PictureBox
        $picLogo.Size     = New-Object System.Drawing.Size($logoSize, $logoSize)
        $picLogo.Location = New-Object System.Drawing.Point(($formWidth - $logoSize - 6), $logoY)
        $picLogo.Image    = [System.Drawing.Image]::FromFile($Config.Branding.LogoPath)
        $picLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $picLogo.BackColor = $clrSurface
        $picLogo.Anchor   = [System.Windows.Forms.AnchorStyles]"Top,Right"
        $form.Controls.Add($picLogo)
    } catch { }
}

# ── LEFT COLUMN ────────────────────────────────────────────────

# Hardware Detection
$pnlHW = New-Panel $pad $hwY $leftW $hwH $clrSurface
$pnlHW.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right"
$lblHWTitle = New-Label "  Hardware Detection" 0 0 ([int]($lInner*0.6)) 22 $fontBold $clrTextDim "MiddleLeft"
$lblModel   = New-Label "  Detecting..." 0 24 $lInner 26 $fontBold $clrText "MiddleLeft"
$pnlHW.Controls.AddRange(@($lblHWTitle, $lblModel))
$form.Controls.Add($pnlHW)

# Network Authentication
$pnlNet = New-Panel $pad $netY $leftW $netH $clrSurface
$pnlNet.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right"
$lblNetTitle  = New-Label "  Network Share" 0 0 ([int]($lInner*0.5)) 22 $fontBold $clrTextDim "MiddleLeft"
$lblShareInfo = New-Label "  $ShareRoot" 0 22 $lInner 18 $fontSmall $clrTextDim "MiddleLeft"
$lblUser      = New-Label "  Username" 0 44 110 24 $fontUI $clrText "MiddleLeft"
$txtUser      = New-TextBox 114 44 ([int]($lInner*0.45)) 24 $false "$DomainPrefix"
$txtUser.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right"
$btnConnect   = New-StyledButton "Connect" ([int]($lInner*0.52)+114) 44 ([int]($lInner*0.22)) 24 $clrAccent
$btnConnect.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Right"
$lblPass      = New-Label "  Password" 0 72 110 24 $fontUI $clrText "MiddleLeft"
$txtPass      = New-TextBox 114 72 ([int]($lInner*0.45)) 24 $true
$txtPass.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right"
$lblConnStatus = New-Label "" ([int]($lInner*0.52)+114) 72 ([int]($lInner*0.28)) 22 $fontSmall $clrTextDim "MiddleLeft"
# Tab order: Username -> Password -> Connect
$txtUser.TabIndex    = 0
$txtPass.TabIndex    = 1
$btnConnect.TabIndex = 2

$pnlNet.Controls.AddRange(@($lblNetTitle, $lblShareInfo, $lblUser, $txtUser,
                             $btnConnect, $lblPass, $txtPass, $lblConnStatus))
$form.Controls.Add($pnlNet)

# OS Image Selection
$pnlImg = New-Panel $pad $imgY $leftW $imgH $clrSurface
$pnlImg.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right,Bottom"
$lblImgTitle   = New-Label "  OS Image" 0 0 ([int]($lInner*0.65)) 26 $fontBold $clrTextDim "MiddleLeft"
$btnRefreshImg = New-StyledButton "Refresh" ($lInner-88) 2 84 24 $clrSurface2
$btnRefreshImg.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Right"
$lbImages      = New-ListBox 4 30 ($lInner-2) ($imgH-52)
$lbImages.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right,Bottom"
$lblImgInfo    = New-Label "  Select an image above" 4 ($imgH-20) ($lInner-2) 18 $fontSmall $clrTextDim "MiddleLeft"
$lblImgInfo.Anchor = [System.Windows.Forms.AnchorStyles]"Bottom,Left"
$pnlImg.Controls.AddRange(@($lblImgTitle, $btnRefreshImg, $lbImages, $lblImgInfo))
$form.Controls.Add($pnlImg)

# Driver Pack Selection
$pnlDrv = New-Panel $pad $drvY $leftW $drvH $clrSurface
$pnlDrv.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right,Bottom"
$lblDrvTitle   = New-Label "  Driver Pack" 0 0 ([int]($lInner*0.65)) 26 $fontBold $clrTextDim "MiddleLeft"
$btnRefreshDrv = New-StyledButton "Refresh" ($lInner-88) 2 84 24 $clrSurface2
$btnRefreshDrv.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Right"
$lbDriverPacks = New-ListBox 4 30 ($lInner-2) ($drvH-52)
$lbDriverPacks.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Left,Right,Bottom"
$lblDrvAutoNote = New-Label "  Auto-matched based on detected model" 4 ($drvH-20) ($lInner-2) 18 $fontSmall $clrSuccess "MiddleLeft"
$lblDrvAutoNote.Anchor = [System.Windows.Forms.AnchorStyles]"Bottom,Left"
$pnlDrv.Controls.AddRange(@($lblDrvTitle, $btnRefreshDrv, $lbDriverPacks, $lblDrvAutoNote))
$form.Controls.Add($pnlDrv)

# ── RIGHT COLUMN ───────────────────────────────────────────────

# Deployment Summary (below logo)
$pnlSummary = New-Panel $rightX $sumY $rightW $sumH $clrSurface
$pnlSummary.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Right"
$lblSumTitle = New-Label "  Summary" 0 0 $rInner 22 $fontBold $clrTextDim "MiddleLeft"

$r1 = 28; $r2 = 52; $r3 = 76; $r4 = 100; $r5 = 124; $r6 = 148
$lX = 6; $lW = 76; $vX = 86; $vW = $rInner - 90

$lblSumModel   = New-Label "  Model:"   $lX $r1 $lW 18 $fontUI $clrTextDim "MiddleLeft"
$lblSumModelV  = New-Label "--"         $vX $r1 $vW 18 $fontBold $clrText "MiddleLeft"
$lblSumST      = New-Label "  Svc Tag:" $lX $r2 $lW 18 $fontUI $clrTextDim "MiddleLeft"
$lblSumSTV     = New-Label "--"         $vX $r2 $vW 18 $fontBold $clrText "MiddleLeft"
$lblSumImage   = New-Label "  Image:"   $lX $r3 $lW 18 $fontUI $clrTextDim "MiddleLeft"
$lblSumImageV  = New-Label "--"         $vX $r3 $vW 18 $fontBold $clrText "MiddleLeft"
$lblSumDriver  = New-Label "  Driver:"  $lX $r4 $lW 18 $fontUI $clrTextDim "MiddleLeft"
$lblSumDriverV = New-Label "--"         $vX $r4 $vW 18 $fontBold $clrText "MiddleLeft"
$lblSumIndex   = New-Label "  Index:"   $lX $r5 60 20 $fontUI $clrTextDim "MiddleLeft"
$txtImageIndex = New-TextBox 68 $r5 44 22 $false "$DefaultIndex"
$lblSumDisk    = New-Label "  Disk:"    130 $r5 50 20 $fontUI $clrTextDim "MiddleLeft"
$txtTargetDisk = New-TextBox 176 $r5 44 22 $false "$DefaultDisk"
$lblWarnWipe   = New-Label "  [!] ERASES target disk!" $lX $r6 $rInner 20 $fontSmall $clrWarning "MiddleLeft"

$pnlSummary.Controls.AddRange(@(
    $lblSumTitle,
    $lblSumModel,  $lblSumModelV,
    $lblSumST,     $lblSumSTV,
    $lblSumImage,  $lblSumImageV,
    $lblSumDriver, $lblSumDriverV,
    $lblSumIndex,  $txtImageIndex, $lblSumDisk, $txtTargetDisk,
    $lblWarnWipe
))
$form.Controls.Add($pnlSummary)

# Progress
$pnlProgress = New-Panel $rightX $progY2 $rightW $progH $clrSurface
$pnlProgress.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Right"
$lblProgressTitle  = New-Label "  Progress" 0 0 $rInner 22 $fontBold $clrTextDim "MiddleLeft"
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(4, 24)
$progressBar.Size     = New-Object System.Drawing.Size(($rInner-2), 18)
$progressBar.Anchor   = [System.Windows.Forms.AnchorStyles]"Top,Left,Right"
$progressBar.Style    = [System.Windows.Forms.ProgressBarStyle]::Continuous
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$progressBar.Value    = 0
$lblProgressStatus = New-Label "  Ready" 0 44 $rInner 18 $fontSmall $clrTextDim "MiddleLeft"
$lblProgressTime   = New-Label "" 0 60 $rInner 16 $fontSmall $clrTextDim "MiddleLeft"
$pnlProgress.Controls.AddRange(@($lblProgressTitle, $progressBar, $lblProgressStatus, $lblProgressTime))
$form.Controls.Add($pnlProgress)

# Deploy Button
$pnlActions = New-Panel $rightX $actY2 $rightW $actH $clrSurface
$pnlActions.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Right"
$btnDeploy = New-StyledButton ">> START DEPLOYMENT" 4 8 ($rInner-2) 36 $clrAccent
$btnDeploy.Font    = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnDeploy.Anchor  = [System.Windows.Forms.AnchorStyles]"Top,Left,Right"
$btnDeploy.Enabled = $false
$pnlActions.Controls.Add($btnDeploy)
$form.Controls.Add($pnlActions)

# Deployment Log
$pnlLog = New-Panel $rightX $logY2 $rightW $logH $clrSurface
$pnlLog.Anchor = [System.Windows.Forms.AnchorStyles]"Top,Right,Bottom"
$lblLogTitle = New-Label "  Deployment Log" 0 0 $rInner 22 $fontBold $clrTextDim "MiddleLeft"
$script:txtLog = New-Object System.Windows.Forms.RichTextBox
$script:txtLog.Location   = New-Object System.Drawing.Point(0, 22)
$script:txtLog.Size       = New-Object System.Drawing.Size($rInner, ($logH-26))
$script:txtLog.Anchor     = [System.Windows.Forms.AnchorStyles]"Top,Left,Right,Bottom"
$script:txtLog.Font       = $fontMono
$script:txtLog.ForeColor  = [System.Drawing.Color]::FromArgb(200, 230, 200)
$script:txtLog.BackColor  = $clrBackground
$script:txtLog.ReadOnly   = $true
$script:txtLog.ScrollBars = "Vertical"
$script:txtLog.WordWrap   = $false
$pnlLog.Controls.AddRange(@($lblLogTitle, $script:txtLog))
$form.Controls.Add($pnlLog)

# Status bar
$pnlStatusBar = New-Panel 0 ($formHeight-$statusH-2) $formWidth $statusH $clrSurface
$pnlStatusBar.Anchor = [System.Windows.Forms.AnchorStyles]"Bottom,Left,Right"
$lblStatus    = New-Label "  Ready - Connect to network share to begin" 0 0 ([int]($formWidth*0.75)) $statusH $fontSmall $clrTextDim "MiddleLeft"
$lblVersion   = New-Label "$AppVersion  WinPE  " 0 0 ($formWidth-6) $statusH $fontSmall $clrTextDim "MiddleRight"
$pnlStatusBar.Controls.AddRange(@($lblStatus, $lblVersion))
$form.Controls.Add($pnlStatusBar)

# ============================================================
#  UPDATE SUMMARY HELPER
# ============================================================
function Update-Summary {
    $imgSel = if ($lbImages.SelectedItem)     { $lbImages.SelectedItem }     else { "--" }
    $drvSel = if ($lbDriverPacks.SelectedItem) { $lbDriverPacks.SelectedItem } else { "--" }

    $lblSumImageV.Text  = $imgSel
    $lblSumDriverV.Text = $drvSel

    if ($script:ModelInfo) {
        $lblSumModelV.Text = $script:ModelInfo.Model
        $lblSumSTV.Text    = $script:ModelInfo.ServiceTag
    }

    # Enable deploy button when all required fields are filled
    $ready = $script:ShareMapped -and
             $lbImages.SelectedIndex -ge 0 -and
             $lbDriverPacks.SelectedIndex -ge 0
    $btnDeploy.Enabled = $ready -and -not $script:DeployRunning
}

# ============================================================
#  EVENT HANDLERS
# ============================================================

#  Form load: detect hardware 
$form.Add_Shown({
    Update-Log "=== $AppTitle Starting ==="
    Update-Log "Detecting hardware..."
    $lblModel.Text      = "  Detecting..."
    $lblModel.ForeColor = $clrTextDim
    $form.Refresh()

    # Retry WMI detection - WinPE WMI service may need a moment to start
    $script:ModelInfo = $null
    $attempts = 0
    while ($null -eq $script:ModelInfo -and $attempts -lt 3) {
        $attempts++
        try {
            $script:ModelInfo = Get-DellModel
        } catch {
            Update-Log "WMI attempt $attempts failed - retrying..."
            Start-Sleep -Seconds 2
        }
    }

    if ($null -eq $script:ModelInfo) {
        $lblModel.Text      = "  [!] Hardware detection failed"
        $lblModel.ForeColor = $clrWarning
        Update-Log "WARNING: Could not detect hardware after 3 attempts."
    } elseif ($script:ModelInfo.IsDell) {
        $lblModel.Text      = "  $($script:ModelInfo.Model)"
        $lblModel.ForeColor = $clrText
        Update-Log "Detected: $($script:ModelInfo.Manufacturer) $($script:ModelInfo.Model)"
        Update-Log "Service Tag: $($script:ModelInfo.ServiceTag)"
        Update-Log "BIOS: $($script:ModelInfo.BIOSVersion)"
    } else {
        $lblModel.Text      = "  [!] Non-Dell hardware: $($script:ModelInfo.Model)"
        $lblModel.ForeColor = $clrWarning
        Update-Log "WARNING: Non-Dell hardware detected."
    }

    Update-Summary
    Set-StatusBadge $lblStatus "  Connect to network share to load images and drivers" $clrTextDim
})

#  Connect button 
$btnConnect.Add_Click({
    if (-not $txtUser.Text.Trim() -or -not $txtPass.Text) {
        Set-StatusBadge $lblConnStatus " Enter credentials" $clrWarning
        return
    }

    $btnConnect.Enabled = $false
    Set-StatusBadge $lblConnStatus " Connecting..." $clrTextDim
    Update-Log "Connecting to $ShareRoot as $($txtUser.Text.Trim())..."

    $secPass = $txtPass.Text | ConvertTo-SecureString -AsPlainText -Force
    $result  = Connect-NetworkShare -SharePath $ShareRoot `
                   -Username $txtUser.Text.Trim() `
                   -Password $secPass `
                   -DriveLetter $DriveLetter

    if ($result.Success) {
        $script:ShareMapped = $true
        Set-StatusBadge $lblConnStatus " [OK] Connected ($DriveLetter)" $clrSuccess
        Update-Log "Share mapped: $DriveLetter -> $ShareRoot"
        Set-StatusBadge $lblStatus "  Connected - Loading images and drivers..." $clrSuccess

        # Populate image list
        $images = Get-AvailableImages -ImagesPath $ImagesPath
        $lbImages.Items.Clear()
        foreach ($img in $images) {
            $lbImages.Items.Add("$($img.Name)  [$($img.SizeGB) GB]")
        }
        # Store full paths for later
        $form.Tag = @{ Images = $images; DriverPacks = @() }

        # Populate driver packs (ZIPs + folders)
        $packs = Get-AvailableDriverPacks -DriversPath $DriversPath
        $lbDriverPacks.Items.Clear()
        foreach ($p in $packs) { $lbDriverPacks.Items.Add($p.DisplayName) }
        ($form.Tag).DriverPacks = $packs

        # Auto-select driver pack for this model
        $drvMatch = Get-DellDriverPack -DriversRoot $DriversPath `
                        -MapFile "$ConfigRoot\DellDriverMap.json"
        $script:SuggestedDriver = $drvMatch

        if ($drvMatch.IsMatched) {
            # Match against DisplayName using both full filename and basename (without .zip)
            $matchIdx = -1
            $packBase = [System.IO.Path]::GetFileNameWithoutExtension($drvMatch.PackName)
            for ($i = 0; $i -lt $lbDriverPacks.Items.Count; $i++) {
                $item = $lbDriverPacks.Items[$i]
                if ($item -like "*$($drvMatch.PackName)*" -or $item -like "*$packBase*") {
                    $matchIdx = $i
                    break
                }
            }
            if ($matchIdx -ge 0) {
                $lbDriverPacks.SelectedIndex = $matchIdx
                $zipTag = if ($drvMatch.IsZip) { " [ZIP]" } else { "" }
                $lblDrvAutoNote.Text      = "  [OK] Auto-matched: $packBase"
                $lblDrvAutoNote.ForeColor = $clrSuccess
                Update-Log "Driver auto-match ($($drvMatch.MatchType))${zipTag}: $($drvMatch.PackName)"
            } else {
                $lblDrvAutoNote.Text      = "  [!] Matched $($drvMatch.PackName) but not found in list - refresh"
                $lblDrvAutoNote.ForeColor = $clrWarning
                Update-Log "WARNING: Auto-match found $($drvMatch.PackName) but could not select in list"
            }
        } else {
            $lblDrvAutoNote.Text      = "  [!] No auto-match found - please select manually"
            $lblDrvAutoNote.ForeColor = $clrWarning
            Update-Log "WARNING: No driver pack auto-matched for $($script:ModelInfo.ModelKey)"
        }

        Update-Summary
        Set-StatusBadge $lblStatus "  Select an image and driver pack, then click Start Deployment" $clrText
    } else {
        $script:ShareMapped = $false
        Set-StatusBadge $lblConnStatus "  Failed" $clrError
        Update-Log "ERROR: $($result.ErrorMessage)"
        Set-StatusBadge $lblStatus "  Connection failed - check credentials and network" $clrError
        $btnConnect.Enabled = $true
    }
})

#  Refresh image list 
$btnRefreshImg.Add_Click({
    if (-not $script:ShareMapped) {
        Set-StatusBadge $lblStatus "  Connect to share first" $clrWarning
        return
    }
    Update-Log "Refreshing image list..."
    $images = Get-AvailableImages -ImagesPath $ImagesPath
    $lbImages.Items.Clear()
    foreach ($img in $images) { $lbImages.Items.Add("$($img.Name)  [$($img.SizeGB) GB]") }
    if ($form.Tag) { ($form.Tag).Images = $images }
    Update-Log "Found $($images.Count) image(s)"
})

#  Refresh driver packs 
$btnRefreshDrv.Add_Click({
    if (-not $script:ShareMapped) {
        Set-StatusBadge $lblStatus "  Connect to share first" $clrWarning
        return
    }
    Update-Log "Refreshing driver pack list..."
    $packs = Get-AvailableDriverPacks -DriversPath $DriversPath
    $lbDriverPacks.Items.Clear()
    foreach ($p in $packs) { $lbDriverPacks.Items.Add($p.Name) }
    if ($form.Tag) { ($form.Tag).DriverPacks = $packs }
    Update-Log "Found $($packs.Count) driver pack(s)"
})

#  Selection changes update summary 
$lbImages.Add_SelectedIndexChanged({ Update-Summary })
$lbDriverPacks.Add_SelectedIndexChanged({ Update-Summary })

# Show image info when selected, auto-detect Dell IA WIM structure
$lbImages.Add_SelectedIndexChanged({
    $idx = $lbImages.SelectedIndex
    if ($idx -ge 0 -and $form.Tag -and $form.Tag.Images.Count -gt $idx) {
        $img = ($form.Tag).Images[$idx]
        $lblImgInfo.Text = "  $($img.Name)  |  $($img.SizeGB) GB  |  Modified: $($img.LastWriteTime.ToString('yyyy-MM-dd'))"

        # Inspect WIM indexes to detect Dell Image Assist structure
        try {
            $wimInfo = Get-WimImageInfo -WimPath $img.FullName
            $isDellIA = ($wimInfo | Where-Object { $_.IsDellIA }) -ne $null

            if ($isDellIA) {
                $txtImageIndex.Text     = "2"
                $lblImgInfo.Text        = "  Dell Image Assist WIM  |  $($img.SizeGB) GB  |  Index 2 = Windows OS  |  5 indexes total"
                $lblImgInfo.ForeColor   = $clrSuccess
                $txtImageIndex.Text = "2"
                Update-Log "Dell Image Assist WIM detected: $($img.Name) -- auto-set index 2 (Windows_IW)"
            } else {
                # Standard WIM -- show index count and deployable indexes
                $deployable = $wimInfo | Where-Object { $_.IsDeployable }
                if ($deployable.Count -eq 1) {
                    $txtImageIndex.Text = "$($deployable[0].Index)"
                    $lblImgInfo.Text    = "  $($img.Name)  |  $($img.SizeGB) GB  |  $($deployable.Count) deployable index"
                } else {
                    $lblImgInfo.Text    = "  $($img.Name)  |  $($img.SizeGB) GB  |  $($deployable.Count) deployable indexes -- verify index"
                }
                $lblImgInfo.ForeColor   = $clrTextDim
            }
        } catch {
            # WIM inspection failed (e.g. share disconnected) - show basic info
            $lblImgInfo.Text      = "  $($img.Name)  |  $($img.SizeGB) GB"
            $lblImgInfo.ForeColor = $clrTextDim
        }
    }
    Update-Summary
})

#  START DEPLOYMENT 
$btnDeploy.Add_Click({
    if ($script:DeployRunning) { return }

    # Validate selections
    if ($lbImages.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select an OS image.", "Selection Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($lbDriverPacks.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select a driver pack.", "Selection Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    # Resolve full image path
    $imgIdx  = $lbImages.SelectedIndex
    $imgInfo = ($form.Tag).Images[$imgIdx]
    $imgPath = $imgInfo.FullName

    $imageIndex = 2
    if (-not [int]::TryParse($txtImageIndex.Text.Trim(), [ref]$imageIndex)) { $imageIndex = 2 }

    # Warn technician if they've manually changed to index 1 on what might be a Dell IA WIM
    if ($imageIndex -eq 1) {
        $warnResult = [System.Windows.Forms.MessageBox]::Show(
            "Image Index is set to 1.`n`nDell Image Assist WIMs use Index 2 for the Windows OS.`nIndex 1 is Dell IA system metadata and is not deployable.`n`nAre you sure you want to use Index 1?",
            "Verify Image Index",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($warnResult -ne "Yes") { return }
    }

    $targetDisk = 0
    if (-not [int]::TryParse($txtTargetDisk.Text.Trim(), [ref]$targetDisk)) { $targetDisk = 0 }

    # Final confirmation dialog
    $confirmMsg = @"
CONFIRM DEPLOYMENT

Model:       $($script:ModelInfo.Model)
Service Tag: $($script:ModelInfo.ServiceTag)

Image:       $($imgInfo.Name)
Driver Pack: $drvName
Image Index: $imageIndex
Target Disk: $targetDisk

[!] WARNING: Disk $targetDisk will be COMPLETELY ERASED.
All data will be permanently lost.

Do you want to proceed?
"@

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        $confirmMsg, "Confirm Deployment",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirm -ne "Yes") {
        Update-Log "Deployment cancelled by user."
        return
    }

    #  Run deployment in background thread 
    $script:DeployRunning = $true
    $btnDeploy.Enabled    = $false
    # Cancel button removed
    $progressBar.Value    = 0
    Set-StatusBadge $lblStatus "  Deployment running..." $clrAccent
    Update-Log "=== DEPLOYMENT STARTED ==="
    Update-Log "Image:       $imgPath"
    Update-Log "Driver Pack: $drvPath"

    # Progress callback runs on background thread - must invoke back to UI thread
    $progressCallback = {
        param([int]$pct, [string]$status)
        # Capture params into script-scope vars before Invoke
        # The [Action] closure cannot see outer param variables directly
        $script:_pct    = $pct
        $script:_status = $status
        $form.Invoke([Action]{
            if ($script:_pct -ge 0) {
                $progressBar.Value = [Math]::Min($script:_pct, 100)
            }
            $lblProgressStatus.Text = "  $script:_status"
            Update-Log $script:_status
        })
    }

    # Resolve selected driver pack
    $drvPackObj  = ($form.Tag).DriverPacks[$lbDriverPacks.SelectedIndex]
    $drvPath     = $drvPackObj.FullName
    $drvIsZip    = $drvPackObj.IsZip

    # Convert Z:\ drive paths to UNC - background runspace doesn't inherit mapped drives
    $uncImgPath = $imgPath -replace [regex]::Escape($DriveLetter), $ShareRoot
    $uncDrvPath = $drvPath -replace [regex]::Escape($DriveLetter), $ShareRoot

    $deployParams = @{
        ImagePath        = $uncImgPath
        DriverPackPath   = $uncDrvPath
        DriverPackIsZip  = $drvIsZip
        ImageIndex       = $imageIndex
        TargetDisk       = $targetDisk
        ProgressCallback = $progressCallback
        ConfirmWipe      = $true
    }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("deployParams",  $deployParams)
    $runspace.SessionStateProxy.SetVariable("ScriptRoot",    $ScriptRoot)
    $runspace.SessionStateProxy.SetVariable("form",          $form)
    $runspace.SessionStateProxy.SetVariable("progressBar",   $progressBar)
    $runspace.SessionStateProxy.SetVariable("lblProgressStatus", $lblProgressStatus)
    $runspace.SessionStateProxy.SetVariable("btnDeploy",     $btnDeploy)
    $runspace.SessionStateProxy.SetVariable("lblStatus",     $lblStatus)
    $runspace.SessionStateProxy.SetVariable("clrSuccess",    $clrSuccess)
    $runspace.SessionStateProxy.SetVariable("clrError",      $clrError)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        . "$ScriptRoot\Logging\Write-DeployLog.ps1"
        . "$ScriptRoot\Core\Apply-Image.ps1"
        . "$ScriptRoot\Core\Inject-Drivers.ps1"
        . "$ScriptRoot\Core\Expand-DriverPack.ps1"
        . "$ScriptRoot\Core\Invoke-Deployment.ps1"
        . "$ScriptRoot\Dell\Get-DellModel.ps1"

        $result = Invoke-Deployment @deployParams

        $form.Invoke([Action]{
            if ($result.Success) {
                $progressBar.Value      = 100
                $lblStatus.ForeColor    = $clrSuccess
                $lblStatus.Text         = "  Deployment complete - rebooting in 15 seconds..."

                # Copy deploy log to C:\ before reboot so it survives
                try {
                    Copy-Item "X:\Deploy\Logs\deploy.log" "W:\Deploy_Log.txt" -Force -ErrorAction SilentlyContinue
                } catch {}

                # Use script-scope counter so timer tick closure can access it
                $script:_rebootCountdown = $RebootSecs
                $script:_rebootTimer = New-Object System.Windows.Forms.Timer
                $script:_rebootTimer.Interval = 1000
                $script:_rebootTimer.Add_Tick({
                    $script:_rebootCountdown--
                    $lblProgressStatus.Text = "  [OK] Deployment successful! Rebooting in $script:_rebootCountdown seconds..."
                    if ($script:_rebootCountdown -le 0) {
                        $script:_rebootTimer.Stop()
                        # Use cmd to call wpeutil - more reliable from WinForms timer
                        Start-Process "wpeutil" -ArgumentList "reboot" -NoNewWindow
                    }
                })
                $script:_rebootTimer.Start()
                $lblProgressStatus.Text = "  [OK] Deployment successful! Rebooting in 15 seconds..."
            } else {
                $progressBar.Value      = 0
                $lblProgressStatus.Text = "  Deployment FAILED: $($result.ErrorMessage)"
                $lblStatus.Text         = "  Deployment failed - check log for details"
                $lblStatus.ForeColor    = $clrError
                $btnDeploy.Enabled      = $true
            }
        })
    })

    [void]$ps.BeginInvoke()
})

# Cancel button removed - DISM cannot be safely cancelled mid-operation

#  F5 = refresh, Escape = confirm exit 
$form.Add_KeyDown({
    if ($_.KeyCode -eq "F5") { $btnRefreshImg.PerformClick(); $btnRefreshDrv.PerformClick() }
    if ($_.KeyCode -eq "Escape" -and -not $script:DeployRunning) {
        $q = [System.Windows.Forms.MessageBox]::Show(
            "Exit to WinPE command prompt?", "Exit", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($q -eq "Yes") { $form.Close() }
    }
})
$form.KeyPreview = $true

#  Status bar 
$pnlStatusBar = New-Panel 0 ($formHeight-$statusH-2) $formWidth $statusH $clrSurface
$pnlStatusBar.Anchor = [System.Windows.Forms.AnchorStyles]"Bottom,Left,Right"
$lblStatus    = New-Label "  Ready - Connect to network share to begin" 0 0 ([int]($formWidth*0.75)) $statusH $fontSmall $clrTextDim "MiddleLeft"
$lblVersion   = New-Label "$AppVersion  WinPE  " 0 0 ($formWidth-4) $statusH $fontSmall $clrTextDim "MiddleRight"
$pnlStatusBar.Controls.AddRange(@($lblStatus, $lblVersion))
$form.Controls.Add($pnlStatusBar)

# ============================================================
#  LAUNCH
# ============================================================
Update-Log "GUI initialized. Waiting for form load..."
[System.Windows.Forms.Application]::Run($form)

