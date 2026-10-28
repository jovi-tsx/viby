# Enumerate live Viby processes and their windows with form state.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement

Get-Process viby -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("process: pid=" + $_.Id + " start=" + $_.StartTime)
}

$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window)))
foreach ($w in $wins) {
    if ($w.Current.Name -like "Viby*") {
        Write-Host ("window: '" + $w.Current.Name + "' pid=" + $w.Current.ProcessId)
        $all = $w.FindAll([System.Windows.Automation.TreeScope]::Subtree,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($el in $all) {
            $t = $el.Current.ControlType.ProgrammaticName
            if ($t -eq "ControlType.StatusBar" -or $t -eq "ControlType.Edit") {
                Write-Host ("  {0} name='{1}' enabled={2}" -f $t, $el.Current.Name, $el.Current.IsEnabled)
            }
        }
    }
}
