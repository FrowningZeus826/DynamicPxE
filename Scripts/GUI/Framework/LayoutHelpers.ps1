# ============================================================
#  LayoutHelpers.ps1
#  Responsive layout factories using DockStyle & TableLayoutPanel
#  Part of DynamicPxE GUI Framework
# ============================================================

function Enable-ControlDoubleBuffering {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Control]$Control
    )

    try {
        $property = $Control.GetType().GetProperty(
            "DoubleBuffered",
            [System.Reflection.BindingFlags]::Instance -bor
            [System.Reflection.BindingFlags]::NonPublic -bor
            [System.Reflection.BindingFlags]::Public
        )

        if ($property -and $property.CanWrite) {
            $property.SetValue($Control, $true, $null)
        }
    } catch {
        # WinPE and some WinForms hosts do not expose this property safely; ignore.
    }
}

function Get-SafePrimaryScreenWorkingArea {
    try {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        if ($screen -and $screen.WorkingArea.Width -gt 0 -and $screen.WorkingArea.Height -gt 0) {
            return $screen.WorkingArea
        }
    } catch {}

    return New-Object System.Drawing.Rectangle(0, 0, 1280, 800)
}

function New-AppShell {
    param(
        [string]$Title,
        [object]$Config,
        [string]$Mode = "Deploy"
    )

    # - Read layout config with defaults -----------
    $sidebarWidth   = Get-ScaledValue 220
    $cardPadding    = Get-ScaledValue 16
    $cardSpacing    = Get-ScaledValue 8
    $minWidth       = 1024
    $minHeight      = 700
    $statusBarH     = Get-ScaledValue 28
    $actionBarH     = Get-ScaledValue 60

    if ($Config) {
        try { if ($Config.Layout.SidebarWidth)    { $sidebarWidth = Get-ScaledValue ([int]$Config.Layout.SidebarWidth) } }    catch {}
        try { if ($Config.Layout.CardPadding)     { $cardPadding  = Get-ScaledValue ([int]$Config.Layout.CardPadding) } }     catch {}
        try { if ($Config.Layout.CardSpacing)     { $cardSpacing  = Get-ScaledValue ([int]$Config.Layout.CardSpacing) } }     catch {}
        try { if ($Config.Layout.MinFormWidth)    { $minWidth     = [int]$Config.Layout.MinFormWidth } }                      catch {}
        try { if ($Config.Layout.MinFormHeight)   { $minHeight    = [int]$Config.Layout.MinFormHeight } }                     catch {}
        try { if ($Config.Layout.StatusBarHeight) { $statusBarH   = Get-ScaledValue ([int]$Config.Layout.StatusBarHeight) } } catch {}
    }

    # - Create main form -------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text             = $Title
    $form.StartPosition    = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle  = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.MaximizeBox      = $true
    $form.MinimumSize      = New-Object System.Drawing.Size($minWidth, $minHeight)
    $form.BackColor        = Get-ThemeColor "Background"
    $form.ForeColor        = Get-ThemeColor "Text"
    $form.Font             = Get-ThemeFont "body"
    $form.AutoScaleMode    = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    Enable-ControlDoubleBuffering -Control $form

    # Size to 90% of screen working area (or minimum)
    $screen = Get-SafePrimaryScreenWorkingArea
    $formW  = [Math]::Max($minWidth, [int]($screen.Width * 0.9))
    $formH  = [Math]::Max($minHeight, [int]($screen.Height * 0.9))
    $form.Size = New-Object System.Drawing.Size($formW, $formH)

    # Load icon from config
    if ($Config) {
        try {
            $iconPath = $null
            try { $iconPath = $Config.Branding.IconPath } catch {}
            if ($iconPath -and (Test-Path $iconPath)) {
                $form.Icon = New-Object System.Drawing.Icon($iconPath)
            }
        } catch {}
    }

    # - Status bar (bottom) -----------------─
    $statusBar = New-Object System.Windows.Forms.Panel
    $statusBar.Dock      = [System.Windows.Forms.DockStyle]::Bottom
    $statusBar.Height    = $statusBarH
    $statusBar.BackColor = Get-ThemeColor "Surface"
    $statusBar.Padding   = New-Object System.Windows.Forms.Padding((Get-ScaledValue 12), 0, (Get-ScaledValue 12), 0)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Dock      = [System.Windows.Forms.DockStyle]::Left
    $lblStatus.AutoSize  = $true
    $lblStatus.Font      = Get-ThemeFont "small"
    $lblStatus.ForeColor = Get-ThemeColor "TextDim"
    $lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblStatus.Text      = "$Mode Tool"
    $lblStatus.Name      = "lblStatusLeft"
    $statusBar.Controls.Add($lblStatus)

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Dock      = [System.Windows.Forms.DockStyle]::Right
    $lblVersion.AutoSize  = $true
    $lblVersion.Font      = Get-ThemeFont "small"
    $lblVersion.ForeColor = Get-ThemeColor "TextMuted"
    $lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $lblVersion.Name      = "lblStatusRight"
    $statusBar.Controls.Add($lblVersion)

    # - Separator line above status bar -----------─
    $statusSep = New-Object System.Windows.Forms.Panel
    $statusSep.Dock      = [System.Windows.Forms.DockStyle]::Bottom
    $statusSep.Height    = 1
    $statusSep.BackColor = Get-ThemeColor "Border"

    # - Action bar (above status bar) ------------─
    $actionBar = New-Object System.Windows.Forms.Panel
    $actionBar.Dock      = [System.Windows.Forms.DockStyle]::Bottom
    $actionBar.Height    = $actionBarH
    $actionBar.BackColor = Get-ThemeColor "Background"
    $actionBar.Padding   = New-Object System.Windows.Forms.Padding($cardPadding, (Get-ScaledValue 10), $cardPadding, (Get-ScaledValue 10))

    # - Separator line above action bar -----------─
    $actionSep = New-Object System.Windows.Forms.Panel
    $actionSep.Dock      = [System.Windows.Forms.DockStyle]::Bottom
    $actionSep.Height    = 1
    $actionSep.BackColor = Get-ThemeColor "Border"

    # - Sidebar (left) --------------------
    $sidebar = New-Object System.Windows.Forms.Panel
    $sidebar.Dock      = [System.Windows.Forms.DockStyle]::Left
    $sidebar.Width     = $sidebarWidth
    $sidebar.BackColor = Get-ThemeColor "SidebarBg"
    $sidebar.Padding   = New-Object System.Windows.Forms.Padding(0, (Get-ScaledValue 16), 0, 0)

    # Sidebar title area
    $sidebarTitle = New-Object System.Windows.Forms.Label
    $sidebarTitle.Dock      = [System.Windows.Forms.DockStyle]::Top
    $sidebarTitle.Height    = Get-ScaledValue 60
    $sidebarTitle.Font      = Get-ThemeFont "heading"
    $sidebarTitle.ForeColor = Get-ThemeColor "Text"
    $sidebarTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $sidebarTitle.Text      = $Title.Split("-")[0].Trim()
    $sidebar.Controls.Add($sidebarTitle)

    # Sidebar separator
    $sidebarSep = New-Object System.Windows.Forms.Panel
    $sidebarSep.Dock      = [System.Windows.Forms.DockStyle]::Top
    $sidebarSep.Height    = 1
    $sidebarSep.BackColor = Get-ThemeColor "Border"
    $sidebar.Controls.Add($sidebarSep)

    # Sidebar steps container
    $sidebarSteps = New-Object System.Windows.Forms.Panel
    $sidebarSteps.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $sidebarSteps.BackColor = Get-ThemeColor "SidebarBg"
    $sidebarSteps.Padding   = New-Object System.Windows.Forms.Padding(0, (Get-ScaledValue 12), 0, 0)
    $sidebarSteps.Name      = "pnlSidebarSteps"
    $sidebar.Controls.Add($sidebarSteps)

    # - Sidebar border (right edge) -------------
    $sidebarBorder = New-Object System.Windows.Forms.Panel
    $sidebarBorder.Dock      = [System.Windows.Forms.DockStyle]::Left
    $sidebarBorder.Width     = 1
    $sidebarBorder.BackColor = Get-ThemeColor "Border"

    # - Content area (fill) -----------------─
    $contentArea = New-Object System.Windows.Forms.Panel
    $contentArea.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $contentArea.BackColor = Get-ThemeColor "Background"
    $contentArea.Padding   = New-Object System.Windows.Forms.Padding($cardPadding)
    $contentArea.AutoScroll = $true

    # - Add controls in correct dock order ----------
    # Dock order matters: added first = docked last in visual order
    $form.Controls.Add($contentArea)      # Fill (added first, fills remaining)
    $form.Controls.Add($sidebarBorder)    # Left border of content
    $form.Controls.Add($sidebar)          # Left
    $form.Controls.Add($actionSep)        # Bottom separator
    $form.Controls.Add($actionBar)        # Bottom
    $form.Controls.Add($statusSep)        # Bottom separator
    $form.Controls.Add($statusBar)        # Bottom

    return @{
        Form         = $form
        Sidebar      = $sidebar
        SidebarSteps = $sidebarSteps
        ContentArea  = $contentArea
        StatusBar    = $statusBar
        ActionBar    = $actionBar
        StatusLeft   = $lblStatus
        StatusRight  = $lblVersion
    }
}

function New-CardPanel {
    param(
        [string]$Title = "",
        [System.Windows.Forms.Control]$Parent = $null,
        [System.Windows.Forms.DockStyle]$DockStyle = [System.Windows.Forms.DockStyle]::Top,
        [int]$Height = 0,
        [switch]$Fill
    )

    $padding = Get-ScaledValue 12
    $radius  = $script:Theme.CornerRadius

    # Outer card panel
    $card = New-Object System.Windows.Forms.Panel
    if ($Fill) {
        $card.Dock = [System.Windows.Forms.DockStyle]::Fill
    } else {
        $card.Dock   = $DockStyle
        if ($Height -gt 0) { $card.Height = Get-ScaledValue $Height }
    }
    $card.BackColor = Get-ThemeColor "CardBg"
    $card.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 0, (Get-ScaledValue 8))
    $card.Padding   = New-Object System.Windows.Forms.Padding($padding)

    # Simple border — no custom paint handler
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    # Content table inside the card
    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.Dock        = [System.Windows.Forms.DockStyle]::Fill
    $table.BackColor   = [System.Drawing.Color]::Transparent
    $table.ColumnCount = 2
    $table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 30))) | Out-Null
    $table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 70))) | Out-Null
    $table.AutoSize    = $true
    $table.AutoScroll  = $false

    $card.Controls.Add($table)
    # Title label (optional)
    $titleLabel = $null
    if ($Title) {
        $titleLabel = New-Object System.Windows.Forms.Label
        $titleLabel.Text      = $Title
        $titleLabel.Dock      = [System.Windows.Forms.DockStyle]::Top
        $titleLabel.Font      = Get-ThemeFont "body"
        $titleLabel.ForeColor = Get-ThemeColor "TextDim"
        $titleLabel.Height    = Get-ScaledValue 30
        $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $titleLabel.BackColor = [System.Drawing.Color]::Transparent
        $titleLabel.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 0, (Get-ScaledValue 6))
        $card.Controls.Add($titleLabel)
    }
    if ($Parent) { $Parent.Controls.Add($card) }

    return @{
        Card       = $card
        ContentTable = $table
        TitleLabel = $titleLabel
    }
}

function New-FormRow {
    param(
        [string]$Label,
        [System.Windows.Forms.Control]$Control,
        [System.Windows.Forms.TableLayoutPanel]$Table,
        [int]$RowIndex
    )

    # Add row style
    $Table.RowCount = [Math]::Max($Table.RowCount, $RowIndex + 1)
    while ($Table.RowStyles.Count -le $RowIndex) {
        $Table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    }

    # Label
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Label
    $lbl.Font      = Get-ThemeFont "bodyBold"
    $lbl.ForeColor = Get-ThemeColor "TextDim"
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lbl.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.Margin    = New-Object System.Windows.Forms.Padding(0, (Get-ScaledValue 4), (Get-ScaledValue 8), (Get-ScaledValue 4))
    $Table.Controls.Add($lbl, 0, $RowIndex)

    # Control
    $Control.Dock   = [System.Windows.Forms.DockStyle]::Fill
    $Control.Margin = New-Object System.Windows.Forms.Padding(0, (Get-ScaledValue 4), 0, (Get-ScaledValue 4))
    $Table.Controls.Add($Control, 1, $RowIndex)

    return $lbl
}

function New-FullWidthRow {
    param(
        [System.Windows.Forms.Control]$Control,
        [System.Windows.Forms.TableLayoutPanel]$Table,
        [int]$RowIndex
    )

    $Table.RowCount = [Math]::Max($Table.RowCount, $RowIndex + 1)
    while ($Table.RowStyles.Count -le $RowIndex) {
        $Table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    }

    $Control.Dock   = [System.Windows.Forms.DockStyle]::Fill
    $Control.Margin = New-Object System.Windows.Forms.Padding(0, (Get-ScaledValue 4), 0, (Get-ScaledValue 4))
    $Table.Controls.Add($Control, 0, $RowIndex)
    $Table.SetColumnSpan($Control, 2)
}

function New-SectionHeader {
    param(
        [string]$Text,
        [System.Windows.Forms.Control]$Parent
    )

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Text.ToUpper()
    $lbl.Dock      = [System.Windows.Forms.DockStyle]::Top
    $lbl.Font      = Get-ThemeFont "small"
    $lbl.ForeColor = Get-ThemeColor "TextMuted"
    $lbl.Height    = Get-ScaledValue 24
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::BottomLeft
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.Padding   = New-Object System.Windows.Forms.Padding(0, 0, 0, (Get-ScaledValue 4))
    if ($Parent) { $Parent.Controls.Add($lbl) }
    return $lbl
}

function New-StyledLabel {
    param(
        [string]$Text = "",
        [string]$FontName = "body",
        [string]$ColorName = "Text",
        [System.Drawing.ContentAlignment]$Align = [System.Drawing.ContentAlignment]::MiddleLeft,
        [switch]$AutoSize
    )

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Text
    $lbl.Font      = Get-ThemeFont $FontName
    $lbl.ForeColor = Get-ThemeColor $ColorName
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.TextAlign = $Align
    $lbl.AutoSize  = [bool]$AutoSize
    return $lbl
}

function New-StyledTextBox {
    param(
        [string]$Text = "",
        [switch]$Password,
        [switch]$Multiline,
        [switch]$ReadOnly,
        [int]$Height = 0
    )

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Font        = Get-ThemeFont "body"
    $tb.ForeColor   = Get-ThemeColor "Text"
    $tb.BackColor   = Get-ThemeColor "SurfaceAlt"
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tb.Text        = $Text
    if ($Password)  { $tb.PasswordChar = [char]0x2022 }
    if ($Multiline) { $tb.Multiline = $true; $tb.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical }
    if ($ReadOnly)  { $tb.ReadOnly = $true; $tb.BackColor = Get-ThemeColor "Surface" }
    if ($Height -gt 0) { $tb.Height = Get-ScaledValue $Height }
    return $tb
}

function New-StyledListBox {
    param([int]$Height = 0)

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Font              = Get-ThemeFont "body"
    $lb.ForeColor         = Get-ThemeColor "Text"
    $lb.BackColor         = Get-ThemeColor "SurfaceAlt"
    $lb.BorderStyle       = [System.Windows.Forms.BorderStyle]::FixedSingle
    $lb.SelectionMode     = [System.Windows.Forms.SelectionMode]::One
    $lb.IntegralHeight    = $false
    if ($Height -gt 0) { $lb.Height = Get-ScaledValue $Height }
    return $lb
}

function New-StyledComboBox {
    param([int]$Height = 0)

    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Font            = Get-ThemeFont "body"
    $cb.ForeColor       = Get-ThemeColor "Text"
    $cb.BackColor       = Get-ThemeColor "SurfaceAlt"
    $cb.FlatStyle       = [System.Windows.Forms.FlatStyle]::Flat
    $cb.DropDownStyle   = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    if ($Height -gt 0) { $cb.Height = Get-ScaledValue $Height }
    return $cb
}

function New-StyledRichTextBox {
    param([switch]$ReadOnly)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Font         = Get-ThemeFont "mono"
    $rtb.ForeColor    = Get-ThemeColor "Success"
    $rtb.BackColor    = Get-ThemeColor "Surface"
    $rtb.BorderStyle  = [System.Windows.Forms.BorderStyle]::None
    $rtb.ReadOnly     = [bool]$ReadOnly
    $rtb.WordWrap     = $false
    $rtb.ScrollBars   = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    return $rtb
}

function New-SpacerPanel {
    param(
        [int]$Height = 8,
        [System.Windows.Forms.DockStyle]$DockStyle = [System.Windows.Forms.DockStyle]::Top
    )

    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock      = $DockStyle
    $spacer.Height    = Get-ScaledValue $Height
    $spacer.BackColor = [System.Drawing.Color]::Transparent
    return $spacer
}
