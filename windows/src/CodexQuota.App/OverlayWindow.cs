using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
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
    private readonly Grid _root = new();
    private readonly Grid _collapsed = new();
    private readonly Grid _expanded = new();
    private readonly TextBlock _collapsedValue = MakeText(14, FontWeights.SemiBold);
    private readonly TextBlock _fiveHourValue = MakeText(12, FontWeights.SemiBold);
    private readonly TextBlock _fiveHourReset = MakeText(8.5, FontWeights.Normal);
    private readonly TextBlock _weeklyValue = MakeText(12, FontWeights.SemiBold);
    private readonly TextBlock _weeklyReset = MakeText(8.5, FontWeights.Normal);
    private readonly Border _surface;
    private readonly DispatcherTimer _leaveTimer;
    private bool _expandedState;
    private bool _programmaticMove;
    private Rect? _entryScreenBounds;
    private int _animationGeneration;

    public OverlayWindow()
    {
        Width = CollapsedWidth;
        Height = CollapsedHeight;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        SnapsToDevicePixels = true;

        var colorBrush = new LinearGradientBrush
        {
            StartPoint = new System.Windows.Point(0, 0),
            EndPoint = new System.Windows.Point(1, 1),
            MappingMode = BrushMappingMode.RelativeToBoundingBox,
            GradientStops =
            {
                new GradientStop(System.Windows.Media.Color.FromArgb(205, 70, 225, 255), 0),
                new GradientStop(System.Windows.Media.Color.FromArgb(190, 122, 97, 255), 0.34),
                new GradientStop(System.Windows.Media.Color.FromArgb(200, 255, 86, 184), 0.68),
                new GradientStop(System.Windows.Media.Color.FromArgb(205, 74, 230, 216), 1),
            },
            RelativeTransform = new RotateTransform(0, 0.5, 0.5),
        };
        if (SystemParameters.ClientAreaAnimation && colorBrush.RelativeTransform is RotateTransform rotation)
        {
            rotation.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(8))
            {
                RepeatBehavior = RepeatBehavior.Forever,
            });
        }

        _surface = new Border
        {
            CornerRadius = new CornerRadius(26),
            Background = new SolidColorBrush(System.Windows.Media.Color.FromArgb(160, 14, 18, 30)),
            BorderBrush = colorBrush,
            BorderThickness = new Thickness(1.25),
            Effect = new System.Windows.Media.Effects.DropShadowEffect
            {
                Color = System.Windows.Media.Color.FromArgb(180, 88, 122, 255),
                BlurRadius = 10,
                ShadowDepth = 0,
                Opacity = 0.42,
            },
            Child = _root,
        };

        ConfigureCollapsed();
        ConfigureExpanded();
        _expanded.Opacity = 0;
        _expanded.IsHitTestVisible = false;
        _root.Children.Add(_collapsed);
        _root.Children.Add(_expanded);
        Content = new Grid { Margin = new Thickness(5), Children = { _surface } };

        _leaveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _leaveTimer.Tick += (_, _) => EvaluatePointerExit();
        MouseEnter += (_, _) => SetExpanded(true);
        MouseLeave += (_, _) => _leaveTimer.Start();
        MouseLeftButtonDown += OnMouseLeftButtonDown;
        LocationChanged += (_, _) => PersistPosition();
        Loaded += (_, _) => RestorePosition();
        SizeChanged += (_, _) => _surface.CornerRadius = new CornerRadius(26 - 4 * ExpansionProgress());
        UpdateSnapshot(UsageSnapshot.Unavailable);
    }

    public void UpdateSnapshot(UsageSnapshot snapshot)
    {
        var collapsed = snapshot.FiveHour.RemainingPercent is not null ? snapshot.FiveHour : snapshot.Weekly;
        _collapsedValue.Text = FormatPercent(collapsed.RemainingPercent);
        _fiveHourValue.Text = $"5h  {FormatPercent(snapshot.FiveHour.RemainingPercent)}";
        _fiveHourReset.Text = FormatReset(snapshot.FiveHour);
        _weeklyValue.Text = $"周   {FormatPercent(snapshot.Weekly.RemainingPercent)}";
        _weeklyReset.Text = FormatReset(snapshot.Weekly);
    }

    public void ShowWithoutActivation()
    {
        if (!IsVisible) Show();
        NativeMethods.ShowWindow(new WindowInteropHelper(this).Handle, NativeMethods.SwShownoactivate);
    }

    private void ConfigureCollapsed()
    {
        _collapsed.HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch;
        _collapsed.VerticalAlignment = VerticalAlignment.Stretch;
        _collapsed.Children.Add(_collapsedValue);
        _collapsedValue.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        _collapsedValue.VerticalAlignment = VerticalAlignment.Center;
        _collapsedValue.Foreground = System.Windows.Media.Brushes.White;
    }

    private void ConfigureExpanded()
    {
        _expanded.Margin = new Thickness(10, 7, 10, 7);
        _expanded.RowDefinitions.Add(new RowDefinition());
        _expanded.RowDefinitions.Add(new RowDefinition());
        _expanded.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _expanded.ColumnDefinitions.Add(new ColumnDefinition());

        AddRow(_fiveHourValue, _fiveHourReset, 0);
        AddRow(_weeklyValue, _weeklyReset, 1);
    }

    private void AddRow(TextBlock value, TextBlock reset, int row)
    {
        value.Foreground = System.Windows.Media.Brushes.White;
        value.VerticalAlignment = VerticalAlignment.Center;
        reset.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromArgb(205, 235, 239, 255));
        reset.TextAlignment = TextAlignment.Right;
        reset.HorizontalAlignment = System.Windows.HorizontalAlignment.Right;
        reset.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetRow(value, row);
        Grid.SetColumn(value, 0);
        Grid.SetRow(reset, row);
        Grid.SetColumn(reset, 1);
        _expanded.Children.Add(value);
        _expanded.Children.Add(reset);
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
        _collapsed.BeginAnimation(OpacityProperty, new DoubleAnimation(expanded ? 0 : 1, TimeSpan.FromMilliseconds(expanded ? 70 : 100))
        {
            BeginTime = expanded ? TimeSpan.Zero : TimeSpan.FromMilliseconds(70),
        });
        _expanded.IsHitTestVisible = expanded;
        _expanded.BeginAnimation(OpacityProperty, new DoubleAnimation(expanded ? 1 : 0, TimeSpan.FromMilliseconds(expanded ? 100 : 70))
        {
            BeginTime = expanded ? TimeSpan.FromMilliseconds(70) : TimeSpan.Zero,
        });
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
        source.AddHook(WndProc);
        var style = NativeMethods.GetWindowLongPtr(source.Handle, NativeMethods.GwlExstyle).ToInt64();
        NativeMethods.SetWindowLongPtr(source.Handle, NativeMethods.GwlExstyle,
            new IntPtr(style | NativeMethods.WsExNoactivate | NativeMethods.WsExToolwindow));
    }

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == NativeMethods.WmNchittest)
        {
            var packed = lParam.ToInt64();
            var screenPoint = new System.Windows.Point((short)(packed & 0xffff), (short)((packed >> 16) & 0xffff));
            var localPoint = PointFromScreen(screenPoint);
            if (!IsInsideRoundedSurface(localPoint, ActualWidth, ActualHeight, _surface.CornerRadius.TopLeft))
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
        const double margin = 5;
        var left = margin;
        var top = margin;
        var right = width - margin;
        var bottom = height - margin;
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

    private double ExpansionProgress() => Math.Clamp((ActualHeight - CollapsedHeight) / (ExpandedHeight - CollapsedHeight), 0, 1);
    private static string FormatPercent(double? value) => value is null ? "--" : $"{Math.Round(value.Value):0}%";
    private static string FormatReset(UsageWindow window)
    {
        if (window.ResetsAt is not { } epoch) return "重置  不可用";
        var local = DateTimeOffset.FromUnixTimeSeconds(epoch).LocalDateTime;
        return local.ToString(window.Kind == UsageWindowKind.Weekly ? "M/d ddd  HH:mm" : "HH:mm", CultureInfo.CurrentCulture);
    }
    private static TextBlock MakeText(double size, FontWeight weight) => new()
    {
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Text"),
        FontSize = size,
        FontWeight = weight,
    };

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
