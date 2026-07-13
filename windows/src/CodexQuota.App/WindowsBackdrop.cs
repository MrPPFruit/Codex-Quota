using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace CodexQuota.App;

internal sealed class WindowsBackdrop
{
    private const int DwmwaSystemBackdropType = 38;
    private const int DwmSystemBackdropNone = 1;
    private const int DwmSystemBackdropTransient = 3;
    private IntPtr _hwnd;
    private (int Width, int Height, int Radius)? _lastRegion;
    private bool _closed;

    internal bool TryEnable(HwndSource source, out string reason)
    {
        _hwnd = source.Handle;
        _closed = false;
        reason = string.Empty;
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621))
        {
            reason = "Windows 11 22621 之前不支持 Desktop Acrylic";
            return false;
        }

        source.CompositionTarget.BackgroundColor = Colors.Transparent;
        var margins = new Margins(-1, -1, -1, -1);
        var extendResult = NativeMethods.DwmExtendFrameIntoClientArea(_hwnd, ref margins);
        var backdrop = DwmSystemBackdropTransient;
        var backdropResult = NativeMethods.DwmSetWindowAttribute(_hwnd, DwmwaSystemBackdropType, ref backdrop, sizeof(int));
        if (extendResult >= 0 && backdropResult >= 0) return true;

        ResetBackdrop();
        reason = $"Desktop Acrylic 初始化失败（extend=0x{extendResult:X8}, backdrop=0x{backdropResult:X8}）";
        return false;
    }

    private void ResetBackdrop()
    {
        if (_closed || _hwnd == IntPtr.Zero) return;
        var backdrop = DwmSystemBackdropNone;
        NativeMethods.DwmSetWindowAttribute(_hwnd, DwmwaSystemBackdropType, ref backdrop, sizeof(int));
        var margins = new Margins(0, 0, 0, 0);
        NativeMethods.DwmExtendFrameIntoClientArea(_hwnd, ref margins);
    }

    internal void DisableMaterial() => ResetBackdrop();

    internal RegionUpdateResult UpdateRegion(double radiusInDip)
    {
        if (_closed || _hwnd == IntPtr.Zero) return RegionUpdateResult.Failed("窗口句柄不可用");
        if (!NativeMethods.GetWindowRect(_hwnd, out var bounds))
            return RegionUpdateResult.Failed($"无法读取窗口边界（win32={Marshal.GetLastWin32Error()}）");
        var width = bounds.Right - bounds.Left;
        var height = bounds.Bottom - bounds.Top;
        var dpi = NativeMethods.GetDpiForWindow(_hwnd);
        if (dpi == 0) return RegionUpdateResult.Failed("无法读取窗口 DPI");
        var radius = Math.Max(0, (int)Math.Round(radiusInDip * dpi / 96.0));
        var regionKey = (width, height, radius);
        if (_lastRegion is { } current && current == regionKey) return RegionUpdateResult.Applied;
        if (width <= 0 || height <= 0) return RegionUpdateResult.Failed("窗口边界为空");

        var region = NativeMethods.CreateRoundRectRgn(0, 0, width, height, radius * 2, radius * 2);
        if (region == IntPtr.Zero)
            return RegionUpdateResult.Failed($"无法创建窗口区域（win32={Marshal.GetLastWin32Error()}）");
        if (NativeMethods.SetWindowRgn(_hwnd, region, true) == 0)
        {
            NativeMethods.DeleteObject(region);
            return RegionUpdateResult.Failed($"无法应用窗口区域（win32={Marshal.GetLastWin32Error()}）");
        }
        _lastRegion = regionKey;
        return RegionUpdateResult.Applied;
    }

    internal void Close()
    {
        if (_closed) return;
        ResetBackdrop();
        _closed = true;
        _hwnd = IntPtr.Zero;
        _lastRegion = null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Margins
    {
        public int Left;
        public int Right;
        public int Top;
        public int Bottom;

        public Margins(int left, int right, int top, int bottom)
        {
            Left = left;
            Right = right;
            Top = top;
            Bottom = bottom;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    private static class NativeMethods
    {
        [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetWindowRect(IntPtr hwnd, out WindowRect rect);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("gdi32.dll", SetLastError = true)] public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int ellipseWidth, int ellipseHeight);
        [DllImport("user32.dll", SetLastError = true)] public static extern int SetWindowRgn(IntPtr hwnd, IntPtr region, [MarshalAs(UnmanagedType.Bool)] bool redraw);
        [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool DeleteObject(IntPtr handle);
    }
}

internal readonly record struct RegionUpdateResult(bool Success, string Reason)
{
    internal static RegionUpdateResult Applied { get; } = new(true, string.Empty);
    internal static RegionUpdateResult Failed(string reason) => new(false, reason);
}
