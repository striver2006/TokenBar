param(
    [int]$X = 2196,
    [int]$Y = 1376,
    [string]$Button = "right"
)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseHelper {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004, RIGHTDOWN = 0x0008, RIGHTUP = 0x0010;
}
"@
# 分小步移动，NotifyIcon 只有光标真实移动才触发 MouseMove（悬停预览也依赖这个）
$fromX = 1600; $fromY = 1300
for ($i = 1; $i -le 10; $i++) {
    [MouseHelper]::SetCursorPos($fromX + [int](($X - $fromX) * $i / 10), $fromY + [int](($Y - $fromY) * $i / 10)) | Out-Null
    Start-Sleep -Milliseconds 30
}
Start-Sleep -Milliseconds 400
if ($Button -eq "right") {
    [MouseHelper]::mouse_event([MouseHelper]::RIGHTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [MouseHelper]::mouse_event([MouseHelper]::RIGHTUP, 0, 0, 0, [UIntPtr]::Zero)
} else {
    [MouseHelper]::mouse_event([MouseHelper]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [MouseHelper]::mouse_event([MouseHelper]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}
