# Probe live Options state: status text, control IsEnabled flags, focused element.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement
$title = "Viby " + [char]0x2014 + " Options"
$cond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $title)),
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window)))
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $cond)
if (-not $win) { Write-Host "options window not found"; exit 1 }
$wr = $win.Current.BoundingRectangle
Write-Host ("window: {0},{1} {2}x{3}" -f $wr.X, $wr.Y, $wr.Width, $wr.Height)
$all = $win.FindAll([System.Windows.Automation.TreeScope]::Subtree,
    [System.Windows.Automation.Condition]::TrueCondition)
foreach ($el in $all) {
    $t = $el.Current.ControlType.ProgrammaticName
    if ($t -in @("ControlType.Edit", "ControlType.ComboBox", "ControlType.CheckBox", "ControlType.Button", "ControlType.StatusBar")) {
        $val = ""
        try { $val = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch {}
        Write-Host ("{0} | name='{1}' | enabled={2} | value='{3}'" -f $t, $el.Current.Name, $el.Current.IsEnabled, $val)
    }
}
$fe = $AE::FocusedElement
if ($fe) { Write-Host ("focused: {0} | {1}" -f $fe.Current.ControlType.ProgrammaticName, $fe.Current.Name) }
