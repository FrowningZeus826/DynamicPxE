# ============================================================
#  ThemeEngine.ps1
#  Centralized color palette, font registry, and DPI scaling
#  Part of DynamicPxE GUI Framework
# ============================================================

# Theme state (populated by Initialize-Theme)
$script:Theme = @{}
$script:DpiScale = 1.0

function New-SafeThemeFont {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Family,
        [Parameter(Mandatory = $true)]
        [float]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [switch]$Monospace
    )

    try {
        return New-Object System.Drawing.Font($Family, $Size, $Style)
    } catch {
        $fallbackFamily = if ($Monospace) { [System.Drawing.FontFamily]::GenericMonospace } else { [System.Drawing.FontFamily]::GenericSansSerif }
        return New-Object System.Drawing.Font($fallbackFamily, $Size, $Style)
    }
}

function Initialize-Theme {
    param([object]$Config)

    # - Compute DPI scale factor ---------------
    try {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        # Create a temporary Graphics to read DPI
        $bmp = New-Object System.Drawing.Bitmap(1, 1)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $script:DpiScale = $gfx.DpiX / 96.0
        $gfx.Dispose()
        $bmp.Dispose()
    } catch {
        $script:DpiScale = 1.0
    }

    # - Default color palette (current dark theme) ------
    $defaults = @{
        Background   = "#121212"
        Surface      = "#1E1E1E"
        SurfaceAlt   = "#282828"
        Accent       = "#0078D4"
        AccentHover  = "#1A8AE0"
        Success      = "#13BA6F"
        Warning      = "#FFB900"
        Error        = "#E81123"
        Text         = "#F0F0F0"
        TextDim      = "#A0A0A0"
        TextMuted    = "#707070"
        Border       = "#3C3C3C"
        SidebarBg    = "#161616"
        SidebarActive = "#0078D4"
        CardBg       = "#1E1E1E"
    }

    # - Default font settings ----------------─
    $fontDefaults = @{
        Family     = "Segoe UI"
        MonoFamily = "Consolas"
        BodySize   = 9
        HeadingSize = 13
        TitleSize  = 18
        SmallSize  = 8
        MonoSize   = 8
    }

    # - Default layout/animation settings ----------─
    $animEnabled  = $true
    $animDuration = 150
    $cornerRadius = 6

    # - Apply config overrides ----------------
    $colors = $defaults.Clone()
    $fonts  = $fontDefaults.Clone()

    if ($Config) {
        # New Theme.Colors section (hex strings)
        try {
            if ($Config.Theme.Colors) {
                $tc = $Config.Theme.Colors
                foreach ($key in $defaults.Keys) {
                    try {
                        $val = $tc.$key
                        if ($val -and $val -match '^#[0-9A-Fa-f]{6}$') {
                            $colors[$key] = $val
                        }
                    } catch {}
                }
            }
        } catch {}

        # Backward compatibility: old Branding.AccentColorR/G/B
        # Only used if Theme.Colors.Accent was not explicitly set
        try {
            if ($Config.Branding -and -not $Config.Theme.Colors.Accent) {
                $r = [int]$Config.Branding.AccentColorR
                $g = [int]$Config.Branding.AccentColorG
                $b = [int]$Config.Branding.AccentColorB
                if ($r -gt 0 -or $g -gt 0 -or $b -gt 0) {
                    $colors["Accent"] = "#{0:X2}{1:X2}{2:X2}" -f $r, $g, $b
                    # Derive hover from accent
                    $colors["AccentHover"] = "#{0:X2}{1:X2}{2:X2}" -f `
                        [Math]::Min(255, $r + 30), `
                        [Math]::Min(255, $g + 30), `
                        [Math]::Min(255, $b + 43)
                    $colors["SidebarActive"] = $colors["Accent"]
                }
            }
        } catch {}

        # Theme.Fonts section
        try {
            if ($Config.Theme.Fonts) {
                $tf = $Config.Theme.Fonts
                try { if ($tf.Family)      { $fonts["Family"]      = $tf.Family } }      catch {}
                try { if ($tf.MonoFamily)   { $fonts["MonoFamily"]  = $tf.MonoFamily } }   catch {}
                try { if ($tf.BodySize)     { $fonts["BodySize"]    = [int]$tf.BodySize } }    catch {}
                try { if ($tf.HeadingSize)  { $fonts["HeadingSize"] = [int]$tf.HeadingSize } } catch {}
                try { if ($tf.TitleSize)    { $fonts["TitleSize"]   = [int]$tf.TitleSize } }   catch {}
                try { if ($tf.SmallSize)    { $fonts["SmallSize"]   = [int]$tf.SmallSize } }   catch {}
                try { if ($tf.MonoSize)     { $fonts["MonoSize"]    = [int]$tf.MonoSize } }    catch {}
            }
        } catch {}

        # Animation settings
        try { if ($null -ne $Config.Theme.AnimationsEnabled)  { $animEnabled  = [bool]$Config.Theme.AnimationsEnabled } }  catch {}
        try { if ($Config.Theme.AnimationDurationMs)          { $animDuration = [int]$Config.Theme.AnimationDurationMs } }  catch {}
        try { if ($Config.Theme.CornerRadius)                 { $cornerRadius = [int]$Config.Theme.CornerRadius } }         catch {}
    }

    # - Build resolved color objects -------------
    $resolvedColors = @{}
    foreach ($key in $colors.Keys) {
        try {
            $resolvedColors[$key] = [System.Drawing.ColorTranslator]::FromHtml($colors[$key])
        } catch {
            # Fallback: parse from defaults
            $resolvedColors[$key] = [System.Drawing.ColorTranslator]::FromHtml($defaults[$key])
        }
    }

    # - Build font objects ------------------
    $family     = $fonts["Family"]
    $monoFamily = $fonts["MonoFamily"]

    $resolvedFonts = @{
        body     = New-SafeThemeFont -Family $family -Size $fonts["BodySize"]
        bodyBold = New-SafeThemeFont -Family $family -Size $fonts["BodySize"] -Style ([System.Drawing.FontStyle]::Bold)
        heading  = New-SafeThemeFont -Family $family -Size $fonts["HeadingSize"] -Style ([System.Drawing.FontStyle]::Bold)
        title    = New-SafeThemeFont -Family $family -Size $fonts["TitleSize"] -Style ([System.Drawing.FontStyle]::Bold)
        small    = New-SafeThemeFont -Family $family -Size $fonts["SmallSize"]
        mono     = New-SafeThemeFont -Family $monoFamily -Size $fonts["MonoSize"] -Monospace
    }

    # - Store in script scope ----------------─
    $script:Theme = @{
        Colors            = $resolvedColors
        Fonts             = $resolvedFonts
        AnimationsEnabled = $animEnabled
        AnimationDurationMs = $animDuration
        CornerRadius      = $cornerRadius
        RawColors         = $colors
        RawFonts          = $fonts
    }
}

function Get-ThemeColor {
    param([string]$Name)
    if ($script:Theme.Colors.ContainsKey($Name)) {
        return $script:Theme.Colors[$Name]
    }
    # Fallback to white if key not found
    return [System.Drawing.Color]::White
}

function Get-ThemeFont {
    param([string]$Name)
    if ($script:Theme.Fonts.ContainsKey($Name)) {
        return $script:Theme.Fonts[$Name]
    }
    return New-SafeThemeFont -Family "Segoe UI" -Size 9
}

function Get-ScaledValue {
    param([int]$BaseValue)
    return [int]([Math]::Round($BaseValue * $script:DpiScale))
}

function Get-AccentHover {
    param([System.Drawing.Color]$Color, [int]$LightenBy = 30)
    return [System.Drawing.Color]::FromArgb(
        [Math]::Min(255, [int]$Color.R + $LightenBy),
        [Math]::Min(255, [int]$Color.G + $LightenBy),
        [Math]::Min(255, [int]$Color.B + [int]($LightenBy * 1.4))
    )
}

function New-ThemeRoundedPath {
    param(
        [System.Drawing.Rectangle]$Rect,
        [int]$Radius = $script:Theme.CornerRadius
    )
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    if ($d -le 0) {
        $path.AddRectangle($Rect)
        return $path
    }
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}
