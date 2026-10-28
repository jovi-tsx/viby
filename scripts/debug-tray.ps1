# Debug 10: definitive probe of #32768 menu windows while the menu is open.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, int extra);' -Name K2 -Namespace W
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int d, int e);' -Name U32 -Namespace W
Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern int GetMenuItemCount(System.IntPtr hMenu);
[DllImport("oleacc.dll")] public static extern int AccessibleObjectFromWindow(System.IntPtr h, uint id, ref System.Guid iid, [MarshalAs(System.Runtime.InteropServices.UnmanagedType.IUnknown)] out object acc);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
public static System.Collections.Generic.List<System.IntPtr> AllMenus() {
    var found = new System.Collections.Generic.List<System.IntPtr>();
    EnumWindows((h, l) => {
        var sb = new System.Text.StringBuilder(64);
        GetClassName(h, sb, 64);
        if (sb.ToString() == "#32768") found.Add(h);
        return true;
    }, System.IntPtr.Zero);
    return found;
}
' -Name Msaa -Namespace W2
$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = $AE::RootElement

# wake + open flyout + right-click Viby
[W.K2]::keybd_event(0x5B, 0, 0, 0); [W.K2]::keybd_event(0x42, 0, 0, 0)
[W.K2]::keybd_event(0x42, 0, 2, 0); [W.K2]::keybd_event(0x5B, 0, 2, 0)
Start-Sleep -Milliseconds 1200
$icon = $root.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "Viby")))
if (-not $icon) {
    $tray = $root.FindFirst([System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, "Shell_TrayWnd")))
    $buttons = $tray.FindAll([System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
    foreach ($b in $buttons) {
        if ($b.Current.Name -match "iconos ocultos|hidden icons") {
            $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Start-Sleep -Seconds 2
            $icon = $root.FindFirst([System.Windows.Automation.TreeScope]::Subtree,
                (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "Viby")))
            break
        }
    }
}
Write-Host "icon: $($null -ne $icon)"
$p = $icon.Current.BoundingRectangle
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point([int]($p.X + 20), [int]($p.Y + 20))
[W.U32]::mouse_event(0x0008, 0, 0, 0, 0)
[W.U32]::mouse_event(0x0010, 0, 0, 0, 0)
Start-Sleep -Milliseconds 800

Add-Type -AssemblyName System.Drawing
$b = New-Object System.Drawing.Bitmap(800, 400)
$g = [System.Drawing.Graphics]::FromImage($b)
$g.CopyFromScreen([int]($p.X - 400), [int]($p.Y - 380), 0, 0, $b.Size)
$b.Save((Join-Path (Split-Path $PSScriptRoot -Parent) "docs\plans\2026-08-13-local-desktop-dictation\artifacts\M1\debug-menu-region.png"))
$g.Dispose(); $b.Dispose()
Start-Sleep -Milliseconds 700

$menus = [W2.Msaa]::AllMenus()
Write-Host "#32768 windows: $($menus.Count)"
foreach ($hwnd in $menus) {
    $vis = [W2.Msaa]::IsWindowVisible($hwnd)
    $hmenu = [W2.Msaa]::SendMessage($hwnd, 0x01E1, [System.IntPtr]::Zero, [System.IntPtr]::Zero)  # MN_GETHMENU
    $count = -1
    if ($hmenu -ne [System.IntPtr]::Zero) { $count = [W2.Msaa]::GetMenuItemCount($hmenu) }
    $iid = New-Object System.Guid("618736e0-3c3d-11cf-810c-00aa00389b71")
    $acc = $null
    $hr = [W2.Msaa]::AccessibleObjectFromWindow($hwnd, [uint32]4294967292, [ref]$iid, [ref]$acc)
    $cc = -1
    if ($acc) { try { $cc = $acc.accChildCount } catch { $cc = -2 } }
    Write-Host ("hwnd={0} visible={1} hmenu={2} items={3} msaa_hr={4} accChildren={5}" -f
        $hwnd, $vis, $hmenu, $count, $hr, $cc)
}
