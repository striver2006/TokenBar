# gui-click.ps1 - DPI-aware mouse click at PHYSICAL pixel coords (small-step move so NotifyIcon sees MouseMove)
param(
    [Parameter(Mandatory=$true)][int]$X,
    [Parameter(Mandatory=$true)][int]$Y,
    [string]$Button = "left",
    [int]$Steps = 10
)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseHelper2 {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    public struct POINT { public int X; public int Y; }
    public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004, RIGHTDOWN = 0x0008, RIGHTUP = 0x0010;
}
"@
[MouseHelper2]::SetProcessDPIAware() | Out-Null
$p = New-Object MouseHelper2+POINT
[MouseHelper2]::GetCursorPos([ref]$p) | Out-Null
$fromX = $p.X; $fromY = $p.Y
for ($i = 1; $i -le $Steps; $i++) {
    [MouseHelper2]::SetCursorPos($fromX + [int](($X - $fromX) * $i / $Steps), $fromY + [int](($Y - $fromY) * $i / $Steps)) | Out-Null
    Start-Sleep -Milliseconds 30
}
Start-Sleep -Milliseconds 400
[MouseHelper2]::SetCursorPos($X, $Y) | Out-Null
Start-Sleep -Milliseconds 100
if ($Button -eq "right") {
    [MouseHelper2]::mouse_event([MouseHelper2]::RIGHTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [MouseHelper2]::mouse_event([MouseHelper2]::RIGHTUP, 0, 0, 0, [UIntPtr]::Zero)
} else {
    [MouseHelper2]::mouse_event([MouseHelper2]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [MouseHelper2]::mouse_event([MouseHelper2]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}
$fx = 0; $fy = 0
[MouseHelper2]::GetCursorPos([ref]$p) | Out-Null
Write-Output ("clicked at physical ({0},{1})" -f $p.X, $p.Y)
