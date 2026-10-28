# Does WebView2's UIA ValuePattern.SetValue fire DOM input events?
# If Save flips to enabled after SetValue, the app's dirty-state listener ran.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
$title = "Viby " + [char]0x2014 + " Options"
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $title)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window)))))
if (-not $win) { Write-Host "options window not found"; exit 1 }
$edit = $win.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Edit)))
$save = $win.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "Save")))))
Write-Host ("save-enabled-before: " + $save.Current.IsEnabled)
$edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("Ctrl+Shift+Space")
Start-Sleep -Milliseconds 600
Write-Host ("save-enabled-after-setvalue: " + $save.Current.IsEnabled)
$status = $win.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::StatusBar)))
Write-Host ("status: '" + $status.Current.Name + "'")
