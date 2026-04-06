# ============================================================
#  PageManager.ps1
#  Wizard page state machine with sidebar step tracking
#  Part of DynamicPxE GUI Framework
# ============================================================

function New-PageManager {
    param(
        [System.Windows.Forms.Panel]$ContentPanel,
        [System.Windows.Forms.Panel]$SidebarPanel,
        [array]$Pages
    )

    $manager = @{
        ContentPanel = $ContentPanel
        SidebarPanel = $SidebarPanel
        Pages        = @()
        ActiveIndex  = -1
        PageControls = @{}
        OnPageChanged = $null
        Locked       = $false
    }

    # Create sidebar steps (added in reverse order because Dock::Top stacks top-down)
    $sidebarSteps = @()
    for ($i = $Pages.Count - 1; $i -ge 0; $i--) {
        $page = $Pages[$i]
        $step = New-SidebarStep -Text $page.Title -Index $i -Total $Pages.Count -Parent $SidebarPanel
        $sidebarSteps = @($step) + $sidebarSteps
    }

    # Create page container panels
    for ($i = 0; $i -lt $Pages.Count; $i++) {
        $page = $Pages[$i]

        # Page content panel (hidden initially)
        $pagePanel = New-Object System.Windows.Forms.Panel
        $pagePanel.Dock      = [System.Windows.Forms.DockStyle]::Fill
        $pagePanel.BackColor = [System.Drawing.Color]::Transparent
        $pagePanel.AutoScroll = $true
        $pagePanel.Visible   = $false
        $pagePanel.Padding   = New-Object System.Windows.Forms.Padding((Get-ScaledValue 8))
        $ContentPanel.Controls.Add($pagePanel)

        # Build page content by calling the scriptblock
        $controls = @{}
        if ($page.BuildContent) {
            try {
                $controls = & $page.BuildContent $pagePanel
                if (-not $controls) { $controls = @{} }
            } catch {
                # If page build fails, show error label
                $errLbl = New-StyledLabel -Text "Error building page: $_" -ColorName "Error"
                $errLbl.Dock = [System.Windows.Forms.DockStyle]::Top
                $pagePanel.Controls.Add($errLbl)
            }
        }

        $manager.PageControls[$page.Name] = $controls

        $manager.Pages += @{
            Name     = $page.Name
            Title    = $page.Title
            Panel    = $pagePanel
            Sidebar  = $sidebarSteps[$i]
            Complete = $false
        }
    }

    # Wire sidebar click handlers
    for ($i = 0; $i -lt $manager.Pages.Count; $i++) {
        $capturedIndex = $i
        $capturedMgr   = $manager
        $manager.Pages[$i].Sidebar.Add_Click({
            if ($capturedMgr.Locked) { return }
            $pg = $capturedMgr.Pages[$capturedIndex]
            # Allow clicking on completed steps or the current step
            if ($pg.Complete -or $capturedIndex -eq $capturedMgr.ActiveIndex) {
                Set-ActivePage -Manager $capturedMgr -Index $capturedIndex
            }
        }.GetNewClosure())
    }

    # Activate first page
    Set-ActivePage -Manager $manager -Index 0

    return $manager
}

function Set-ActivePage {
    param(
        [hashtable]$Manager,
        [int]$Index
    )

    if ($Index -lt 0 -or $Index -ge $Manager.Pages.Count) { return }

    # Hide current page
    if ($Manager.ActiveIndex -ge 0 -and $Manager.ActiveIndex -lt $Manager.Pages.Count) {
        $current = $Manager.Pages[$Manager.ActiveIndex]
        $current.Panel.Visible = $false
        if (-not $current.Complete) {
            Set-SidebarStepState -Step $current.Sidebar -State "inactive"
        }
    }

    # Show new page
    $Manager.ActiveIndex = $Index
    $target = $Manager.Pages[$Index]
    $target.Panel.Visible = $true
    Set-SidebarStepState -Step $target.Sidebar -State "active"

    # Update all sidebar states
    for ($i = 0; $i -lt $Manager.Pages.Count; $i++) {
        $pg = $Manager.Pages[$i]
        if ($i -eq $Index) {
            Set-SidebarStepState -Step $pg.Sidebar -State "active"
        } elseif ($pg.Complete) {
            Set-SidebarStepState -Step $pg.Sidebar -State "completed"
        } else {
            Set-SidebarStepState -Step $pg.Sidebar -State "inactive"
        }
    }

    if ($Manager.OnPageChanged) {
        try {
            & $Manager.OnPageChanged $Manager $Index
        } catch {}
    }
}

function Set-PageComplete {
    param(
        [hashtable]$Manager,
        [int]$Index
    )

    if ($Index -lt 0 -or $Index -ge $Manager.Pages.Count) { return }
    $Manager.Pages[$Index].Complete = $true

    # Update sidebar visual if not currently active
    if ($Index -ne $Manager.ActiveIndex) {
        Set-SidebarStepState -Step $Manager.Pages[$Index].Sidebar -State "completed"
    }
}

function Set-PageIncomplete {
    param(
        [hashtable]$Manager,
        [int]$Index
    )

    if ($Index -lt 0 -or $Index -ge $Manager.Pages.Count) { return }
    $Manager.Pages[$Index].Complete = $false

    if ($Index -ne $Manager.ActiveIndex) {
        Set-SidebarStepState -Step $Manager.Pages[$Index].Sidebar -State "inactive"
    }
}

function Get-PageControls {
    param(
        [hashtable]$Manager,
        [string]$PageName
    )

    if ($Manager.PageControls.ContainsKey($PageName)) {
        return $Manager.PageControls[$PageName]
    }
    return @{}
}

function Advance-ToNextPage {
    param(
        [hashtable]$Manager
    )

    $next = $Manager.ActiveIndex + 1
    if ($next -lt $Manager.Pages.Count) {
        Set-ActivePage -Manager $Manager -Index $next
    }
}

function Get-AllPagesComplete {
    param(
        [hashtable]$Manager,
        [int[]]$RequiredPages = @()
    )

    if ($RequiredPages.Count -gt 0) {
        foreach ($idx in $RequiredPages) {
            if ($idx -ge 0 -and $idx -lt $Manager.Pages.Count) {
                if (-not $Manager.Pages[$idx].Complete) { return $false }
            }
        }
        return $true
    }

    # All pages must be complete
    foreach ($pg in $Manager.Pages) {
        if (-not $pg.Complete) { return $false }
    }
    return $true
}
