# ============================================================
#  Initialize-GUIFramework.ps1
#  Master loader for the DynamicPxE GUI Framework
#  Dot-source this single file to load all framework components
# ============================================================

# Load .NET assemblies for WinForms
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Load framework components in dependency order
. "$PSScriptRoot\ThemeEngine.ps1"
. "$PSScriptRoot\LayoutHelpers.ps1"
. "$PSScriptRoot\AnimationEngine.ps1"
. "$PSScriptRoot\CustomControls.ps1"
. "$PSScriptRoot\PageManager.ps1"
