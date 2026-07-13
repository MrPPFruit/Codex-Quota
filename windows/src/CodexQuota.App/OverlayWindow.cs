using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using CodexQuota.Core;
using Microsoft.Win32;

namespace CodexQuota.App;

internal sealed class OverlayWindow : Window
{
    private const double CollapsedWidth = 52;
    private const double CollapsedHeight = 52;
    private const double ExpandedWidth = 130;
    private const double ExpandedHeight = 78;
    private readonly OverlaySurface _surface = new();
    private readonly WindowsBackdrop _backdrop = new();
    private readonly DispatcherTimer _leaveTimer;
    private readonly BoundedDiagnosticLog? _diagnostics;
    private bool _expandedState;
    private bool _programmaticMove;
    private Rect? _entryScreenBounds;
    private int _animationGeneration;
    private bool _regionReady;
    private bool _closed;
    private bool _nativeReady;
    private string? _lastRegionFailure;
    private bool _resumeAfterRegionRecovery;

    public OverlayWindow(BoundedDiagnosticLog? diagnostics = null)
    {
        _diagnostics = diagnostics;
        Width = CollapsedWidth;
        Height = CollapsedHeight;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = false;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        SnapsToDevicePixels = true;

        Content = _surface;

        _leaveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _leaveTimer.Tick += (_, _) => EvaluatePointerExit();
        MouseEnter += (_, _) => SetExpanded(true);
        MouseLeave += (_, _) => _leaveTimer.Start();
        MouseLeftButtonDown += OnMouseLeftButtonDown;
        LocationChanged += (_, _) => PersistPosition();
        Loaded += (_, _) => RestorePosition();
        SizeChanged += (_, _) => RefreshWindowRegion();
        DpiChanged += (_, _) => RefreshWindowRegion();
        Closed += (_, _) => CloseNativeSurface();
        UpdateSnapshot(UsageSnapshot.Unavailable);
    }

    public void UpdateSnapshot(UsageSnapshot snapshot)
    {
        _surface.UpdateSnapshot(snapshot);
    }

    public void ShowWithoutActivation()
    {
        if (!IsVisible) Show();
        if (!_regionReady) RefreshWindowRegion();
        if (!_regionReady)
        {
            _resumeAfterRegionRecovery = true;
            Hide();
            return;
        }
        NativeMethods.ShowWindow(new WindowInteropHelper(this).Handle, NativeMethods.SwShownoactivate);
    }

    private void SetExpanded(bool expanded)
    {
        _leaveTimer.Stop();
        if (_expandedState == expanded) return;
        if (expanded)
        {
            var topLeft = PointToScreen(new System.Windows.Point(0, 0));
            var bottomRight = PointToScreen(new System.Windows.Point(ActualWidth, ActualHeight));
            _entryScreenBounds = new Rect(topLeft, bottomRight);
        }
        _expandedState = expanded;
        var animationGeneration = ++_animationGeneration;
        var duration = SystemParameters.ClientAreaAnimation ? TimeSpan.FromMilliseconds(180) : TimeSpan.Zero;
        var easing = new CubicEase { EasingMode = EasingMode.EaseOut };
        var targetWidth = expanded ? ExpandedWidth : CollapsedWidth;
        var targetHeight = expanded ? ExpandedHeight : CollapsedHeight;
        var centerX = Left + ActualWidth / 2;
        var centerY = Top + ActualHeight / 2;
        var virtualDesktop = new DesktopRect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
        var targetFrame = OverlayPlacement.ClampCentered(centerX, centerY, targetWidth, targetHeight, virtualDesktop)
            ?? new OverlayFrame(Left, Top, targetWidth, targetHeight);
        var targetLeft = targetFrame.Left;
        var targetTop = targetFrame.Top;

        _programmaticMove = true;
        BeginAnimation(WidthProperty, new DoubleAnimation(ActualWidth, targetWidth, duration) { EasingFunction = easing });
        BeginAnimation(HeightProperty, new DoubleAnimation(ActualHeight, targetHeight, duration) { EasingFunction = easing });
        BeginAnimation(LeftProperty, new DoubleAnimation(Left, targetLeft, duration) { EasingFunction = easing });
        BeginAnimation(TopProperty, new DoubleAnimation(Top, targetTop, duration) { EasingFunction = easing });
        _surface.SetExpanded(expanded, duration > TimeSpan.Zero);
        var timer = new DispatcherTimer { Interval = duration + TimeSpan.FromMilliseconds(20) };
        timer.Tick += (_, _) =>
        {
            if (animationGeneration != _animationGeneration)
            {
                timer.Stop();
                return;
            }
            BeginAnimation(WidthProperty, null);
            BeginAnimation(HeightProperty, null);
            BeginAnimation(LeftProperty, null);
            BeginAnimation(TopProperty, null);
            Width = targetWidth;
            Height = targetHeight;
            Left = targetLeft;
            Top = targetTop;
            RefreshWindowRegion();
            if (!expanded) _entryScreenBounds = null;
            _programmaticMove = false;
            timer.Stop();
        };
        timer.Start();
    }

    private void EvaluatePointerExit()
    {
        _leaveTimer.Stop();
        if (!_expandedState) return;
        var point = System.Windows.Forms.Control.MousePosition;
        var localPoint = PointFromScreen(new System.Windows.Point(point.X, point.Y));
        var safeArea = new Rect(-10, -10, ActualWidth + 20, ActualHeight + 20);
        var entryArea = _entryScreenBounds is { } entry ? new Rect(entry.X - 10, entry.Y - 10, entry.Width + 20, entry.Height + 20) : Rect.Empty;
        if (!safeArea.Contains(localPoint) && !entryArea.Contains(new System.Windows.Point(point.X, point.Y))) SetExpanded(false);
        else _leaveTimer.Start();
    }

    private void OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed) return;
        var frozenLeft = Left;
        var frozenTop = Top;
        var frozenWidth = ActualWidth;
        var frozenHeight = ActualHeight;
        _animationGeneration++;
        BeginAnimation(LeftProperty, null);
        BeginAnimation(TopProperty, null);
        BeginAnimation(WidthProperty, null);
        BeginAnimation(HeightProperty, null);
        Left = frozenLeft;
        Top = frozenTop;
        Width = frozenWidth;
        Height = frozenHeight;
        _programmaticMove = false;
        try { DragMove(); } catch (InvalidOperationException) { }
        var centerX = Left + ActualWidth / 2;
        var centerY = Top + ActualHeight / 2;
        var targetWidth = _expandedState ? ExpandedWidth : CollapsedWidth;
        var targetHeight = _expandedState ? ExpandedHeight : CollapsedHeight;
        _programmaticMove = true;
        Width = targetWidth;
        Height = targetHeight;
        Left = centerX - targetWidth / 2;
        Top = centerY - targetHeight / 2;
        _programmaticMove = false;
        PersistPosition();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var source = (HwndSource)PresentationSource.FromVisual(this);
        _nativeReady = true;
        source.AddHook(WndProc);
        var style = NativeMethods.GetWindowLongPtr(source.Handle, NativeMethods.GwlExstyle).ToInt64();
        NativeMethods.SetWindowLongPtr(source.Handle, NativeMethods.GwlExstyle,
            new IntPtr(style | NativeMethods.WsExNoactivate | NativeMethods.WsExToolwindow));
        var backdropAvailable = _backdrop.TryEnable(source, out var backdropReason);
        _surface.SetBackdropAvailable(backdropAvailable);
        if (!backdropAvailable) _diagnostics?.Write("overlay-material", backdropReason);
        RefreshWindowRegion();
    }

    private void RefreshWindowRegion()
    {
        if (_closed || !_nativeReady) return;
        var result = _backdrop.UpdateRegion(OverlaySurface.CornerRadiusForHeight(ActualHeight));
        _regionReady = result.Success;
        if (result.Success)
        {
            _lastRegionFailure = null;
            if (_resumeAfterRegionRecovery)
            {
                _resumeAfterRegionRecovery = false;
                ShowWithoutActivation();
            }
            return;
        }
        _backdrop.DisableMaterial();
        _surface.SetBackdropAvailable(false);
        if (_lastRegionFailure != result.Reason) _diagnostics?.Write("overlay-region", result.Reason);
        _lastRegionFailure = result.Reason;
        if (IsLoaded && IsVisible)
        {
            _resumeAfterRegionRecovery = true;
            Hide();
        }
    }

    private void CloseNativeSurface()
    {
        _closed = true;
        _nativeReady = false;
        _regionReady = false;
        _resumeAfterRegionRecovery = false;
        _backdrop.Close();
    }

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == NativeMethods.WmNchittest)
        {
            var packed = lParam.ToInt64();
            var screenPoint = new System.Windows.Point((short)(packed & 0xffff), (short)((packed >> 16) & 0xffff));
            var localPoint = PointFromScreen(screenPoint);
            if (!IsInsideRoundedSurface(localPoint, ActualWidth, ActualHeight, _surface.CornerRadius))
            {
                handled = true;
                return new IntPtr(NativeMethods.Httransparent);
            }
        }
        if (message == NativeMethods.WmMouseactivate)
        {
            handled = true;
            return new IntPtr(NativeMethods.MaNoactivate);
        }
        return IntPtr.Zero;
    }

    internal static bool IsInsideRoundedSurface(System.Windows.Point point, double width, double height, double radius)
    {
        const double left = 0;
        const double top = 0;
        var right = width;
        var bottom = height;
        if (point.X < left || point.X > right || point.Y < top || point.Y > bottom) return false;
        radius = Math.Clamp(radius, 0, Math.Min((right - left) / 2, (bottom - top) / 2));
        if (point.X >= left + radius && point.X <= right - radius) return true;
        if (point.Y >= top + radius && point.Y <= bottom - radius) return true;
        var centerX = point.X < left + radius ? left + radius : right - radius;
        var centerY = point.Y < top + radius ? top + radius : bottom - radius;
        var dx = point.X - centerX;
        var dy = point.Y - centerY;
        return dx * dx + dy * dy <= radius * radius;
    }

    private void RestorePosition()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\CodexQuota", writable: false);
            if (double.TryParse(key?.GetValue("CenterX") as string, NumberStyles.Float, CultureInfo.InvariantCulture, out var centerX) &&
                double.TryParse(key?.GetValue("CenterY") as string, NumberStyles.Float, CultureInfo.InvariantCulture, out var centerY))
            {
                Left = Math.Clamp(centerX - Width / 2, SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - Width);
                Top = Math.Clamp(centerY - Height / 2, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - Height);
                return;
            }
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException) { }
        var work = SystemParameters.WorkArea;
        Left = work.Right - Width - 32;
        Top = work.Bottom - Height - 32;
    }

    private void PersistPosition()
    {
        if (_programmaticMove || !IsLoaded) return;
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\CodexQuota", writable: true);
            key.SetValue("CenterX", (Left + ActualWidth / 2).ToString(CultureInfo.InvariantCulture), RegistryValueKind.String);
            key.SetValue("CenterY", (Top + ActualHeight / 2).ToString(CultureInfo.InvariantCulture), RegistryValueKind.String);
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException) { }
    }

    private static class NativeMethods
    {
        public const int GwlExstyle = -20, WsExNoactivate = 0x08000000, WsExToolwindow = 0x00000080;
        public const int WmMouseactivate = 0x0021, WmNchittest = 0x0084, MaNoactivate = 3, SwShownoactivate = 4;
        public const int Httransparent = -1;
        [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
        [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hwnd, int command);
    }
}
