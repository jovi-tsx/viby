# Shared UIA/MSAA tray and window helpers for the native smokes.
# Extracted from smoke-m1.ps1 2026-08-15; dot-source, do not copy.
# Requires: Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes,
# System.Drawing, System.Windows.Forms and $AE/$CT/$root in scope.

function Find-First($parent, $type, $name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
    if ($type) {
        $cond = New-Object System.Windows.Automation.AndCondition($cond,
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $type)))
    }
    $parent.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $cond)
}

function Right-Click-At($x, $y) {
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int d, int e);' `
        -Name U32 -Namespace W -ErrorAction SilentlyContinue
    [W.U32]::mouse_event(0x0008, 0, 0, 0, 0)  # right down
    [W.U32]::mouse_event(0x0010, 0, 0, 0, 0)  # right up
}

function Right-Click($element) {
    $p = $element.Current.BoundingRectangle
    Right-Click-At ([int]($p.X + $p.Width / 2)) ([int]($p.Y + $p.Height / 2))
}

# Windows 11 on-demand UIA: the taskbar subtree only exists while focused.
# Win+B focuses the notification area and materializes it.
function Send-WinB {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, int extra);' `
        -Name K2 -Namespace W -ErrorAction SilentlyContinue
    [W.K2]::keybd_event(0x5B, 0, 0, 0)
    [W.K2]::keybd_event(0x42, 0, 0, 0)
    [W.K2]::keybd_event(0x42, 0, 2, 0)
    [W.K2]::keybd_event(0x5B, 0, 2, 0)
    Start-Sleep -Milliseconds 1200
}

# Windows 11 hides unpinned tray icons in the overflow flyout, whose UIA
# subtree only exists while open. Find the icon directly; if absent, open
# the flyout (locale-agnostic chevron match) and look again.
function Find-TrayIcon {
    Send-WinB
    $icon = Find-First $root $CT::Button "Viby"
    if ($icon) { return $icon }
    $tray = $root.FindFirst([System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty, "Shell_TrayWnd")))
    if (-not $tray) { return $null }
    $buttons = $tray.FindAll([System.Windows.Automation.TreeScope]::Subtree,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
    foreach ($b in $buttons) {
        if ($b.Current.Name -match "iconos ocultos|hidden icons") {
            $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Start-Sleep -Seconds 2
            return (Find-First $root $CT::Button "Viby")
        }
    }
    return $null
}

$report = @()
function Note($line) { $script:report += $line; Write-Host $line }

# Classic Win32 popup menus (#32768) do not expose items to UIA; they answer
# to MSAA (oleacc IAccessible). Read and invoke items through it.
Add-Type -MemberDefinition '
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern System.IntPtr FindWindow(string c, string w);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
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
[DllImport("user32.dll")] public static extern System.IntPtr SendMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern int GetMenuItemCount(System.IntPtr hMenu);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetMenuStringW(System.IntPtr hMenu, uint i, System.Text.StringBuilder s, int max, uint flags);
[DllImport("user32.dll")] public static extern bool GetMenuItemRect(System.IntPtr hWnd, System.IntPtr hMenu, uint i, out RECT rc);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rc);
public struct RECT { public int Left, Top, Right, Bottom; }
public static RECT GetWindowRectValue(System.IntPtr hwnd) {
    RECT rc;
    GetWindowRect(hwnd, out rc);
    return rc;
}
public static string[] GetMenuTexts(System.IntPtr hwnd) {
    var hMenu = SendMessage(hwnd, 0x01E1, System.IntPtr.Zero, System.IntPtr.Zero);  // MN_GETHMENU
    if (hMenu == System.IntPtr.Zero) return new string[0];
    int count = GetMenuItemCount(hMenu);
    if (count <= 0) return new string[0];
    var texts = new string[count];
    for (uint i = 0; i < count; i++) {
        var sb = new System.Text.StringBuilder(256);
        GetMenuStringW(hMenu, i, sb, 256, 0x00000400);  // MF_BYPOSITION
        texts[i] = sb.ToString();
    }
    return texts;
}
public static RECT GetItemRect(System.IntPtr hwnd, uint i) {
    var hMenu = SendMessage(hwnd, 0x01E1, System.IntPtr.Zero, System.IntPtr.Zero);
    RECT rc;
    GetMenuItemRect(hwnd, hMenu, i, out rc);
    return rc;
}
' -Name Msaa -Namespace W2 -ErrorAction SilentlyContinue

$script:MenuTexts = @()
function Get-TrayMenuItems {
    $names = $null
    for ($try = 0; $try -lt 6 -and -not $names; $try++) {
        foreach ($hwnd in [W2.Msaa]::AllMenus()) {
            $texts = [W2.Msaa]::GetMenuTexts($hwnd)
            if (@($texts | Where-Object { $_ }).Count -gt 0) {
                $script:MenuHwnd = $hwnd
                $script:MenuTexts = $texts
                $names = ,$texts
                break
            }
        }
        if (-not $names) { Start-Sleep -Milliseconds 400 }
    }
    return $names
}

function Left-Click($x, $y) {
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
    [W.U32]::mouse_event(0x0002, 0, 0, 0, 0)  # left down
    [W.U32]::mouse_event(0x0004, 0, 0, 0, 0)  # left up
}

Add-Type -MemberDefinition '
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(System.IntPtr h, bool force);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int command);
' -Name FG -Namespace W -ErrorAction SilentlyContinue

# Foreground stealing is locked for background processes; z-order is not.
# TOPMOST puts the window above every non-topmost window so clicks land on it.
function Set-Topmost($element, [bool]$on) {
    $h = [System.IntPtr]$element.Current.NativeWindowHandle
    $after = if ($on) { [System.IntPtr]::new(-1) } else { [System.IntPtr]::new(-2) }
    [W.FG]::SetWindowPos($h, $after, 0, 0, 0, 0, 0x0003) | Out-Null  # NOMOVE|NOSIZE
    if ($on) {
        [W.FG]::SetForegroundWindow($h) | Out-Null
        [W.FG]::SwitchToThisWindow($h, $true)
    }
    Start-Sleep -Milliseconds 300
}

function Hide-Window($element) {
    [W.FG]::ShowWindow([System.IntPtr]$element.Current.NativeWindowHandle, 0) | Out-Null
}

function Invoke-TrayMenuItem($name) {
    for ($i = 0; $i -lt $script:MenuTexts.Count; $i++) {
        $clean = $script:MenuTexts[$i].Replace("&", "").Split("`t")[0]
        if ($clean -eq $name) {
            $rc = [W2.Msaa]::GetItemRect($script:MenuHwnd, [uint32]$i)
            Left-Click ([int](($rc.Left + $rc.Right) / 2)) ([int](($rc.Top + $rc.Bottom) / 2))
            return
        }
    }
    throw "menu item '$name' not found in: $($script:MenuTexts -join ', ')"
}

# Right-clicking the flyout icon is racy (the flyout can close between the
# UIA read and the click). Retry until a real #32768 menu window exists.
function Open-TrayMenu {
    for ($i = 0; $i -lt 8; $i++) {
        $icon = Find-TrayIcon
        Note "open-menu-attempt-$($i+1): icon=$($null -ne $icon)"
        if ($icon) {
            Start-Sleep -Milliseconds 400
            Right-Click $icon
            Start-Sleep -Milliseconds 1200
            $count = [W2.Msaa]::AllMenus().Count
            Note "open-menu-attempt-$($i+1): menus=$count"
            if ($count -gt 0) { return $true }
            [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
        }
        Start-Sleep -Milliseconds 800
    }
    return $false
}
