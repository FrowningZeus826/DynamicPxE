# ============================================================
#  CustomControls.ps1
#  Owner-drawn modern controls for WinForms
#  Part of DynamicPxE GUI Framework
# ============================================================

# Cached brushes/pens to avoid GDI+ allocation in Paint events
$script:CachedBrushes = @{}
$script:CachedPens    = @{}

# Inline rounded path builder — safe inside .GetNewClosure() scriptblocks
# where New-ThemeRoundedPath is not resolvable.
$script:BuildRoundedPath = {
    param([System.Drawing.Rectangle]$Rect, [int]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    if ($d -le 0 -or $Rect.Width -le 0 -or $Rect.Height -le 0) {
        $p.AddRectangle($Rect)
    } else {
        $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
        $p.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
        $p.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
        $p.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
        $p.CloseFigure()
    }
    return $p
}

# Inline brush/pen builders — safe inside .GetNewClosure() scriptblocks
# where Get-CachedBrush/Get-CachedPen are not resolvable.
$script:BrushCache = $script:CachedBrushes
$script:PenCache   = $script:CachedPens
$script:GetBrush = {
    param([System.Drawing.Color]$Color)
    $key = "$($Color.R),$($Color.G),$($Color.B),$($Color.A)"
    if (-not $script:BrushCache.ContainsKey($key)) {
        $script:BrushCache[$key] = New-Object System.Drawing.SolidBrush($Color)
    }
    return $script:BrushCache[$key]
}
$script:GetPen = {
    param([System.Drawing.Color]$Color, [float]$Width = 1)
    $key = "$($Color.R),$($Color.G),$($Color.B),$($Color.A),$Width"
    if (-not $script:PenCache.ContainsKey($key)) {
        $script:PenCache[$key] = New-Object System.Drawing.Pen($Color, $Width)
    }
    return $script:PenCache[$key]
}

function Get-CachedBrush {
    param([System.Drawing.Color]$Color)
    $key = "$($Color.R),$($Color.G),$($Color.B),$($Color.A)"
    if (-not $script:CachedBrushes.ContainsKey($key)) {
        $script:CachedBrushes[$key] = New-Object System.Drawing.SolidBrush($Color)
    }
    return $script:CachedBrushes[$key]
}

function Get-CachedPen {
    param([System.Drawing.Color]$Color, [float]$Width = 1)
    $key = "$($Color.R),$($Color.G),$($Color.B),$($Color.A),$Width"
    if (-not $script:CachedPens.ContainsKey($key)) {
        $script:CachedPens[$key] = New-Object System.Drawing.Pen($Color, $Width)
    }
    return $script:CachedPens[$key]
}

function New-RoundedButton {
    param(
        [string]$Text,
        [int]$Width  = 160,
        [int]$Height = 36,
        [System.Drawing.Color]$Color = (Get-ThemeColor "Accent"),
        [int]$Radius = 0,
        [switch]$Large,
        [switch]$Secondary
    )

    if ($Radius -le 0) { $Radius = $script:Theme.CornerRadius }
    $scaledW = Get-ScaledValue $Width
    $scaledH = Get-ScaledValue $Height
    if ($Large) { $scaledH = Get-ScaledValue 44 }

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = $Text
    $btn.Size      = New-Object System.Drawing.Size($scaledW, $scaledH)
    $btn.Font      = if ($Large) { Get-ThemeFont "bodyBold" } else { Get-ThemeFont "body" }
    $btn.ForeColor = Get-ThemeColor "Text"
    $btn.BackColor = $Color
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.FlatAppearance.MouseOverBackColor = $Color  # Prevent default, we paint manually
    $btn.FlatAppearance.MouseDownBackColor = $Color
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btn.TabStop   = $true

    if ($Secondary) {
        $btn.BackColor = Get-ThemeColor "Surface"
        $btn.ForeColor = Get-ThemeColor "TextDim"
        $Color = Get-ThemeColor "Surface"
    }

    # Set rounded region for hit testing
    $capturedRadius = $Radius
    $buildPath = $script:BuildRoundedPath
    $btn.Add_Resize({
        $rect = New-Object System.Drawing.Rectangle(0, 0, $this.Width, $this.Height)
        $path = & $buildPath -Rect $rect -Radius $capturedRadius
        $this.Region = New-Object System.Drawing.Region($path)
        $path.Dispose()
    }.GetNewClosure())

    # Custom paint for rounded appearance
    $textColor = $btn.ForeColor
    $bgColor   = $Color
    $btnFont   = $btn.Font
    $getBrush  = $script:GetBrush
    $btn.Add_Paint({
        param($sender, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

            $rect = New-Object System.Drawing.Rectangle(0, 0, ($sender.Width - 1), ($sender.Height - 1))
            $path = & $buildPath -Rect $rect -Radius $capturedRadius

            $brush = & $getBrush -Color $sender.BackColor
            $g.FillPath($brush, $path)

            # Draw text centered
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment     = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rectF = New-Object System.Drawing.RectangleF(0, 0, $sender.Width, $sender.Height)
            $g.DrawString($sender.Text, $btnFont, (& $getBrush -Color $textColor), $rectF, $sf)
            $sf.Dispose()
            $path.Dispose()
        } catch {}
    }.GetNewClosure())

    # Hover animation
    $hoverColor = Get-AccentHover -Color $Color
    New-HoverAnimation -Control $btn -FromColor $Color -ToColor $hoverColor

    return $btn
}

function New-RoundedPanel {
    param(
        [int]$Radius = 0,
        [System.Drawing.Color]$BackgroundColor = (Get-ThemeColor "CardBg"),
        [System.Drawing.Color]$BorderColor = (Get-ThemeColor "Border"),
        [switch]$NoBorder
    )

    if ($Radius -le 0) { $Radius = $script:Theme.CornerRadius }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor    = $BackgroundColor
    Enable-ControlDoubleBuffering -Control $panel

    $capturedRadius = $Radius
    $capturedBg     = $BackgroundColor
    $capturedBorder = $BorderColor
    $drawBorder     = -not $NoBorder
    $buildPath      = $script:BuildRoundedPath
    $getBrush       = $script:GetBrush
    $getPen         = $script:GetPen

    $panel.Add_Paint({
        param($sender, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $rect = New-Object System.Drawing.Rectangle(0, 0, ($sender.Width - 1), ($sender.Height - 1))
            $path = & $buildPath -Rect $rect -Radius $capturedRadius
            $g.FillPath((& $getBrush -Color $capturedBg), $path)
            if ($drawBorder) {
                $g.DrawPath((& $getPen -Color $capturedBorder), $path)
            }
            $path.Dispose()
        } catch {}
    }.GetNewClosure())

    return $panel
}

function New-GradientProgressBar {
    param(
        [int]$Height = 20
    )

    $scaledH = Get-ScaledValue $Height
    $radius  = [Math]::Min($script:Theme.CornerRadius, [int]($scaledH / 2))

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Height      = $scaledH
    $panel.Dock        = [System.Windows.Forms.DockStyle]::Top
    $panel.BackColor   = [System.Drawing.Color]::Transparent
    $panel.Tag         = 0  # Current value 0-100

    $bgColor        = Get-ThemeColor "Surface"
    $accentColor    = Get-ThemeColor "Accent"
    $accentLight    = Get-AccentHover -Color $accentColor -LightenBy 40
    $capturedRadius = $radius
    $buildPath      = $script:BuildRoundedPath
    $getBrush       = $script:GetBrush

    $panel.Add_Paint({
        param($sender, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

            $w = $sender.Width - 1
            $h = $sender.Height - 1
            $val = [int]$sender.Tag

            # Background track
            $bgRect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
            $bgPath = & $buildPath -Rect $bgRect -Radius $capturedRadius
            $g.FillPath((& $getBrush -Color $bgColor), $bgPath)
            $bgPath.Dispose()

            # Filled portion
            if ($val -gt 0) {
                $fillW = [Math]::Max($capturedRadius * 2, [int]($w * $val / 100))
                $fillRect = New-Object System.Drawing.Rectangle(0, 0, $fillW, $h)
                $fillPath = & $buildPath -Rect $fillRect -Radius $capturedRadius

                try {
                    $gradBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                        $fillRect, $accentColor, $accentLight,
                        [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
                    $g.FillPath($gradBrush, $fillPath)
                    $gradBrush.Dispose()
                } catch {
                    $g.FillPath((& $getBrush -Color $accentColor), $fillPath)
                }
                $fillPath.Dispose()
            }
        } catch {}
    }.GetNewClosure())

    return $panel
}

function Set-Progress {
    param(
        [System.Windows.Forms.Panel]$Bar,
        [int]$Value
    )
    $Bar.Tag = [Math]::Max(0, [Math]::Min(100, $Value))
    $Bar.Invalidate()
}

function New-SidebarStep {
    param(
        [string]$Text,
        [int]$Index,
        [int]$Total,
        [System.Windows.Forms.Control]$Parent
    )

    $stepH   = Get-ScaledValue 44
    $barW    = Get-ScaledValue 4
    $padLeft = Get-ScaledValue 16

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock      = [System.Windows.Forms.DockStyle]::Top
    $panel.Height    = $stepH
    $panel.BackColor = Get-ThemeColor "SidebarBg"
    $panel.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $panel.Tag       = @{ Index = $Index; State = "inactive" }  # inactive, active, completed

    $accentColor  = Get-ThemeColor "SidebarActive"
    $successColor = Get-ThemeColor "Success"
    $textColor    = Get-ThemeColor "Text"
    $dimColor     = Get-ThemeColor "TextDim"
    $mutedColor   = Get-ThemeColor "TextMuted"
    $sidebarBg    = Get-ThemeColor "SidebarBg"
    $fontNormal   = Get-ThemeFont "body"
    $fontBold     = Get-ThemeFont "bodyBold"
    $stepText     = $Text
    $stepIndex    = $Index
    $getBrush     = $script:GetBrush
    $getPen       = $script:GetPen

    $panel.Add_Paint({
        param($sender, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

            $info = $sender.Tag
            $st   = $info.State

            # Background
            $g.Clear($sidebarBg)

            # Active indicator bar (left edge)
            if ($st -eq "active") {
                $barRect = New-Object System.Drawing.Rectangle(0, 0, $barW, $sender.Height)
                $g.FillRectangle((& $getBrush -Color $accentColor), $barRect)
            }

            # Step number or checkmark
            $numX = $barW + $padLeft
            $numY = ($sender.Height - 20) / 2
            $numRect = New-Object System.Drawing.RectangleF($numX, $numY, 20, 20)

            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment     = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center

            if ($st -eq "completed") {
                # Checkmark circle
                $circleRect = New-Object System.Drawing.Rectangle([int]$numX, [int]$numY, 20, 20)
                $g.FillEllipse((& $getBrush -Color $successColor), $circleRect)
                $g.DrawString([char]0x2713, $fontNormal, (& $getBrush -Color $textColor), $numRect, $sf)
            } else {
                # Step number
                $numColor = if ($st -eq "active") { $accentColor } else { $mutedColor }
                $circleRect = New-Object System.Drawing.Rectangle([int]$numX, [int]$numY, 20, 20)
                $g.DrawEllipse((& $getPen -Color $numColor), $circleRect)
                $g.DrawString(($stepIndex + 1).ToString(), $fontNormal, (& $getBrush -Color $numColor), $numRect, $sf)
            }

            # Step label
            $lblX = $numX + 28
            $lblRect = New-Object System.Drawing.RectangleF($lblX, 0, ($sender.Width - $lblX - 8), $sender.Height)
            $lblFont  = if ($st -eq "active") { $fontBold } else { $fontNormal }
            $lblColor = if ($st -eq "active") { $textColor } elseif ($st -eq "completed") { $dimColor } else { $mutedColor }
            $sfLeft = New-Object System.Drawing.StringFormat
            $sfLeft.Alignment     = [System.Drawing.StringAlignment]::Near
            $sfLeft.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString($stepText, $lblFont, (& $getBrush -Color $lblColor), $lblRect, $sfLeft)

            $sf.Dispose()
            $sfLeft.Dispose()
        } catch {}
    }.GetNewClosure())

    if ($Parent) { $Parent.Controls.Add($panel) }
    return $panel
}

function Set-SidebarStepState {
    param(
        [System.Windows.Forms.Panel]$Step,
        [ValidateSet("inactive","active","completed")]
        [string]$State
    )
    $info = $Step.Tag
    $info.State = $State
    $Step.Tag = $info
    $Step.Invalidate()
}

function New-StatusDot {
    param(
        [System.Drawing.Color]$Color = (Get-ThemeColor "TextMuted"),
        [int]$Size = 10
    )

    $scaledSize = Get-ScaledValue $Size
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size      = New-Object System.Drawing.Size($scaledSize, $scaledSize)
    $panel.BackColor = [System.Drawing.Color]::Transparent
    $panel.Tag       = $Color

    $getBrush = $script:GetBrush
    $panel.Add_Paint({
        param($sender, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $dotColor = $sender.Tag
            $rect = New-Object System.Drawing.Rectangle(1, 1, ($sender.Width - 3), ($sender.Height - 3))
            $g.FillEllipse((& $getBrush -Color $dotColor), $rect)
        } catch {}
    }.GetNewClosure())

    return $panel
}

function Set-StatusDotColor {
    param(
        [System.Windows.Forms.Panel]$Dot,
        [System.Drawing.Color]$Color
    )
    $Dot.Tag = $Color
    $Dot.Invalidate()
}

function New-ToastNotification {
    param(
        [string]$Message,
        [ValidateSet("info","success","warning","error")]
        [string]$Type = "info",
        [int]$Duration = 4000,
        [System.Windows.Forms.Control]$Parent
    )

    if (-not $Parent) { return }

    $colorMap = @{
        info    = Get-ThemeColor "Accent"
        success = Get-ThemeColor "Success"
        warning = Get-ThemeColor "Warning"
        error   = Get-ThemeColor "Error"
    }
    $stripeColor = $colorMap[$Type]

    $toastW = Get-ScaledValue 320
    $toastH = Get-ScaledValue 48
    $stripeW = Get-ScaledValue 4
    $pad = Get-ScaledValue 12

    $toast = New-Object System.Windows.Forms.Panel
    $toast.Size      = New-Object System.Drawing.Size($toastW, $toastH)
    $toast.BackColor = Get-ThemeColor "Surface"

    # Position at bottom-right of parent, initially off-screen
    $x = $Parent.ClientSize.Width + 10
    $y = $Parent.ClientSize.Height - $toastH - $pad
    $toast.Location = New-Object System.Drawing.Point($x, $y)

    $capturedStripe  = $stripeColor
    $capturedBg      = Get-ThemeColor "Surface"
    $capturedBorder  = Get-ThemeColor "Border"
    $radius    = $script:Theme.CornerRadius
    $buildPath = $script:BuildRoundedPath
    $getBrush  = $script:GetBrush
    $getPen    = $script:GetPen

    $toast.Add_Paint({
        param($sender, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $rect = New-Object System.Drawing.Rectangle(0, 0, ($sender.Width - 1), ($sender.Height - 1))
            $path = & $buildPath -Rect $rect -Radius $radius
            $g.FillPath((& $getBrush -Color $capturedBg), $path)
            $g.DrawPath((& $getPen -Color $capturedBorder), $path)
            # Left stripe
            $stripeRect = New-Object System.Drawing.Rectangle(0, 0, $stripeW, $sender.Height)
            $g.FillRectangle((& $getBrush -Color $capturedStripe), $stripeRect)
            $path.Dispose()
        } catch {}
    }.GetNewClosure())

    # Message label
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Message
    $lbl.Font      = Get-ThemeFont "small"
    $lbl.ForeColor = Get-ThemeColor "Text"
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.Location  = New-Object System.Drawing.Point(($stripeW + $pad), 0)
    $lbl.Size      = New-Object System.Drawing.Size(($toastW - $stripeW - $pad - $pad), $toastH)
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $toast.Controls.Add($lbl)

    $Parent.Controls.Add($toast)
    $toast.BringToFront()

    # Slide in
    New-SlideAnimation -Control $toast -Direction "In" -Edge "Right"

    # Auto-dismiss timer
    $dismissTimer = New-Object System.Windows.Forms.Timer
    $dismissTimer.Interval = $Duration
    $capturedToast = $toast
    $capturedParent = $Parent
    $dismissTimer.Add_Tick({
        $dismissTimer.Stop()
        $dismissTimer.Dispose()
        New-SlideAnimation -Control $capturedToast -Direction "Out" -Edge "Right" -OnComplete {
            try { $capturedParent.Controls.Remove($capturedToast); $capturedToast.Dispose() } catch {}
        }.GetNewClosure()
    }.GetNewClosure())
    $dismissTimer.Start()

    return $toast
}
