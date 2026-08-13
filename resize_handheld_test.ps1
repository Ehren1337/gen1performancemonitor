$signature = @'
using System;
using System.Runtime.InteropServices;
public static class WindowTools {
  [DllImport("user32.dll")]
  public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
    int X, int Y, int cx, int cy, uint flags);
}
'@

Add-Type -TypeDefinition $signature
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    $process = Get-Process -Name love,lovec -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1
    if ($process) {
        [WindowTools]::SetWindowPos(
            $process.MainWindowHandle,
            [IntPtr]::Zero,
            0, 0, 640, 480, 0x0004)
        exit 0
    }
    Start-Sleep -Milliseconds 250
}
exit 1
