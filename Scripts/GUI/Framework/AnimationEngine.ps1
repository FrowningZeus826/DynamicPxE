# ============================================================
#  AnimationEngine.ps1
#  Timer-based smooth color transitions and slide animations
#  Part of DynamicPxE GUI Framework
# ============================================================

# Active animation timers (for cleanup)
$script:ActiveAnimations = @{}

function New-HoverAnimation {
    param(
        [System.Windows.Forms.Control]$Control,
        [System.Drawing.Color]$FromColor,
        [System.Drawing.Color]$ToColor,
        [int]$Duration = 0
    )

    # Use theme duration if not specified
    if ($Duration -le 0) {
        $Duration = $script:Theme.AnimationDurationMs
        if ($Duration -le 0) { $Duration = 150 }
    }

    $animEnabled = $script:Theme.AnimationsEnabled

    if (-not $animEnabled) {
        # Instant swap — no timers
        $capturedFrom = $FromColor
        $capturedTo   = $ToColor
        $Control.Add_MouseEnter({
            $this.BackColor = $capturedTo
        }.GetNewClosure())
        $Control.Add_MouseLeave({
            $this.BackColor = $capturedFrom
        }.GetNewClosure())
        return
    }

    # Animated hover — lerp between colors over Duration
    $state = @{
        Control   = $Control
        From      = $FromColor
        To        = $ToColor
        Duration  = $Duration
        Progress  = 0.0     # 0.0 = From, 1.0 = To
        Direction = 0       # 1 = entering, -1 = leaving
        Timer     = $null
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 16  # ~60fps
    $timer.Add_Tick({
        $s = $state
        $step = 16.0 / $s.Duration
        $s.Progress += $step * $s.Direction
        $s.Progress = [Math]::Max(0.0, [Math]::Min(1.0, $s.Progress))

        $t = $s.Progress
        $r = [int]($s.From.R + ($s.To.R - $s.From.R) * $t)
        $g = [int]($s.From.G + ($s.To.G - $s.From.G) * $t)
        $b = [int]($s.From.B + ($s.To.B - $s.From.B) * $t)
        $s.Control.BackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Max(0, [Math]::Min(255, $r)),
            [Math]::Max(0, [Math]::Min(255, $g)),
            [Math]::Max(0, [Math]::Min(255, $b))
        )

        # Stop when fully transitioned
        if (($s.Direction -eq 1 -and $s.Progress -ge 1.0) -or
            ($s.Direction -eq -1 -and $s.Progress -le 0.0)) {
            $s.Timer.Stop()
        }
    }.GetNewClosure())

    $state.Timer = $timer

    $Control.Add_MouseEnter({
        $state.Direction = 1
        $state.Timer.Start()
    }.GetNewClosure())

    $Control.Add_MouseLeave({
        $state.Direction = -1
        $state.Timer.Start()
    }.GetNewClosure())

    # Track for cleanup
    $id = [System.Guid]::NewGuid().ToString()
    $script:ActiveAnimations[$id] = $timer

    $Control.Add_Disposed({
        if ($state.Timer) {
            $state.Timer.Stop()
            $state.Timer.Dispose()
        }
    }.GetNewClosure())
}

function New-SlideAnimation {
    param(
        [System.Windows.Forms.Control]$Control,
        [ValidateSet("In","Out")]
        [string]$Direction = "In",
        [ValidateSet("Right","Bottom")]
        [string]$Edge = "Right",
        [int]$Duration = 300,
        [scriptblock]$OnComplete = $null
    )

    if (-not $script:Theme.AnimationsEnabled) {
        # Instant — just show/hide
        if ($Direction -eq "In") {
            $Control.Visible = $true
        } else {
            $Control.Visible = $false
            if ($OnComplete) { & $OnComplete }
        }
        return
    }

    $parent = $Control.Parent
    if (-not $parent) { return }

    # Calculate start and end positions
    if ($Edge -eq "Right") {
        $endX = $parent.ClientSize.Width - $Control.Width - (Get-ScaledValue 12)
        $startX = $parent.ClientSize.Width + 10
        $y = $Control.Location.Y
        if ($Direction -eq "In") {
            $Control.Location = New-Object System.Drawing.Point($startX, $y)
        }
    } else {
        $endY = $parent.ClientSize.Height - $Control.Height - (Get-ScaledValue 12)
        $startY = $parent.ClientSize.Height + 10
        $x = $Control.Location.X
        if ($Direction -eq "In") {
            $Control.Location = New-Object System.Drawing.Point($x, $startY)
        }
    }

    $Control.Visible = $true

    $state = @{
        Control   = $Control
        Edge      = $Edge
        Direction = $Direction
        Duration  = $Duration
        Elapsed   = 0
        Timer     = $null
        OnComplete = $OnComplete
    }

    if ($Edge -eq "Right") {
        $state.StartVal = if ($Direction -eq "In") { $startX } else { $endX }
        $state.EndVal   = if ($Direction -eq "In") { $endX }   else { $startX }
        $state.FixedVal = $y
    } else {
        $state.StartVal = if ($Direction -eq "In") { $startY } else { $endY }
        $state.EndVal   = if ($Direction -eq "In") { $endY }   else { $startY }
        $state.FixedVal = $x
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 16
    $timer.Add_Tick({
        $s = $state
        $s.Elapsed += 16
        $t = [Math]::Min(1.0, $s.Elapsed / $s.Duration)

        # Ease-out cubic
        $eased = 1.0 - [Math]::Pow(1.0 - $t, 3)

        $val = [int]($s.StartVal + ($s.EndVal - $s.StartVal) * $eased)

        if ($s.Edge -eq "Right") {
            $s.Control.Location = New-Object System.Drawing.Point($val, $s.FixedVal)
        } else {
            $s.Control.Location = New-Object System.Drawing.Point($s.FixedVal, $val)
        }

        if ($t -ge 1.0) {
            $s.Timer.Stop()
            $s.Timer.Dispose()
            if ($s.Direction -eq "Out") {
                $s.Control.Visible = $false
            }
            if ($s.OnComplete) { & $s.OnComplete }
        }
    }.GetNewClosure())

    $state.Timer = $timer
    $timer.Start()
}

function Clear-AllAnimations {
    foreach ($timer in $script:ActiveAnimations.Values) {
        try {
            $timer.Stop()
            $timer.Dispose()
        } catch {}
    }
    $script:ActiveAnimations = @{}
}
