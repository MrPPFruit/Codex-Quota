using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using CodexQuota.Core;
using Brush = System.Windows.Media.Brush;
using Color = System.Windows.Media.Color;
using FontFamily = System.Windows.Media.FontFamily;

namespace CodexQuota.App;

internal sealed class OverlaySurface : Grid
{
    private static readonly Lazy<ImageSource> AuroraTexture = new(CreateAuroraTexture);
    private static readonly Color Primary = Color.FromArgb(235, 26, 28, 38);
    private static readonly Color Secondary = Color.FromArgb(173, 46, 51, 69);

    private readonly Border _baseLayer = new();
    private readonly Border _colorLayer = new();
    private readonly System.Windows.Controls.Image _colorImage = new();
    private readonly Grid _collapsed = new();
    private readonly Grid _expanded = new();
    private readonly TextBlock _collapsedValue = MakeText(17, FontWeights.Bold);
    private readonly TextBlock _collapsedLabel = MakeText(9.5, FontWeights.Medium);
    private readonly TextBlock _fiveHourValue = MakeText(14, FontWeights.Bold);
    private readonly TextBlock _fiveHourResetDate = MakeText(9, FontWeights.Normal);
    private readonly TextBlock _fiveHourResetTime = MakeText(9, FontWeights.Normal);
    private readonly TextBlock _weeklyValue = MakeText(14, FontWeights.Bold);
    private readonly TextBlock _weeklyResetDate = MakeText(9, FontWeights.Normal);
    private readonly TextBlock _weeklyResetTime = MakeText(9, FontWeights.Normal);
    private readonly RotateTransform _auroraRotation = new(0);
    private readonly CultureInfo _culture;
    private readonly TimeZoneInfo _timeZone;
    private int _contentTransitionGeneration;

    public OverlaySurface(
        bool animateColorFlow = true,
        CultureInfo? culture = null,
        TimeZoneInfo? timeZone = null)
    {
        _culture = culture ?? CultureInfo.CurrentCulture;
        _timeZone = timeZone ?? TimeZoneInfo.Local;
        ClipToBounds = true;
        SnapsToDevicePixels = true;

        _colorImage.Source = AuroraTexture.Value;
        _colorImage.Width = 152;
        _colorImage.Height = 152;
        _colorImage.Stretch = Stretch.Fill;
        _colorImage.Opacity = 0.60;
        _colorImage.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        _colorImage.VerticalAlignment = System.Windows.VerticalAlignment.Center;
        _colorImage.RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);
        _colorImage.RenderTransform = _auroraRotation;
        _colorLayer.Child = _colorImage;
        if (animateColorFlow && SystemParameters.ClientAreaAnimation)
        {
            _auroraRotation.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(10))
            {
                RepeatBehavior = RepeatBehavior.Forever,
            });
        }

        _baseLayer.Background = new SolidColorBrush(Color.FromArgb(178, 255, 255, 255));
        ConfigureCollapsed();
        ConfigureExpanded();
        _expanded.Opacity = 0;
        _expanded.IsHitTestVisible = false;
        _expanded.Visibility = Visibility.Collapsed;
        AutomationProperties.SetIsOffscreenBehavior(_collapsed, IsOffscreenBehavior.Onscreen);
        AutomationProperties.SetIsOffscreenBehavior(_expanded, IsOffscreenBehavior.Offscreen);
        Children.Add(_baseLayer);
        Children.Add(_colorLayer);
        Children.Add(_collapsed);
        Children.Add(_expanded);
        SizeChanged += (_, _) => UpdateShape();
        UpdateSnapshot(UsageSnapshot.Unavailable);
        UpdateShape();
    }

    internal double CornerRadius => CornerRadiusForHeight(ActualHeight);

    internal static double CornerRadiusForHeight(double height) =>
        26 - 4 * Math.Clamp((height - 52) / (78 - 52), 0, 1);

    internal void SetBackdropAvailable(bool available)
    {
        _baseLayer.Background = new SolidColorBrush(available
            ? Color.FromArgb(178, 255, 255, 255)
            : Color.FromRgb(243, 245, 248));
    }

    internal void SetFlowAngle(double angle)
    {
        _auroraRotation.BeginAnimation(RotateTransform.AngleProperty, null);
        _auroraRotation.Angle = angle;
    }

    internal void SetExpanded(bool expanded, bool animate)
    {
        var transitionGeneration = ++_contentTransitionGeneration;
        _collapsed.Visibility = Visibility.Visible;
        _expanded.Visibility = Visibility.Visible;
        _expanded.IsHitTestVisible = expanded;
        AutomationProperties.SetIsOffscreenBehavior(_collapsed, expanded ? IsOffscreenBehavior.Offscreen : IsOffscreenBehavior.Onscreen);
        AutomationProperties.SetIsOffscreenBehavior(_expanded, expanded ? IsOffscreenBehavior.Onscreen : IsOffscreenBehavior.Offscreen);
        if (!animate)
        {
            _collapsed.BeginAnimation(OpacityProperty, null);
            _expanded.BeginAnimation(OpacityProperty, null);
            _collapsed.Opacity = expanded ? 0 : 1;
            _expanded.Opacity = expanded ? 1 : 0;
            _collapsed.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
            _expanded.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            return;
        }
        var outgoingDuration = animate ? TimeSpan.FromMilliseconds(70) : TimeSpan.Zero;
        var incomingDuration = animate ? TimeSpan.FromMilliseconds(100) : TimeSpan.Zero;
        var delay = animate ? TimeSpan.FromMilliseconds(70) : TimeSpan.Zero;
        _collapsed.BeginAnimation(OpacityProperty, new DoubleAnimation(expanded ? 0 : 1, expanded ? outgoingDuration : incomingDuration)
        {
            BeginTime = expanded ? TimeSpan.Zero : delay,
        });
        _expanded.BeginAnimation(OpacityProperty, new DoubleAnimation(expanded ? 1 : 0, expanded ? incomingDuration : outgoingDuration)
        {
            BeginTime = expanded ? delay : TimeSpan.Zero,
        });
        var timer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(180),
        };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (transitionGeneration != _contentTransitionGeneration) return;
            _collapsed.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
            _expanded.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        };
        timer.Start();
    }

    internal void UpdateSnapshot(UsageSnapshot snapshot)
    {
        var collapsed = SelectCollapsed(snapshot);
        _collapsedValue.Text = FormatPercent(collapsed.RemainingPercent);
        _collapsedValue.Foreground = BrushFor(collapsed.RemainingPercent);
        _collapsedLabel.Text = collapsed.Label;

        _fiveHourValue.Text = FormatPercent(snapshot.FiveHour.RemainingPercent);
        _fiveHourValue.Foreground = BrushFor(snapshot.FiveHour.RemainingPercent);
        SetReset(_fiveHourResetDate, _fiveHourResetTime, snapshot.FiveHour, _culture, _timeZone);

        _weeklyValue.Text = FormatPercent(snapshot.Weekly.RemainingPercent);
        _weeklyValue.Foreground = BrushFor(snapshot.Weekly.RemainingPercent);
        SetReset(_weeklyResetDate, _weeklyResetTime, snapshot.Weekly, _culture, _timeZone);
    }

    internal static CollapsedSurfacePresentation SelectCollapsed(UsageSnapshot snapshot)
    {
        if (IsDisplayable(snapshot.FiveHour))
            return new CollapsedSurfacePresentation("5h", snapshot.FiveHour.RemainingPercent);
        if (IsDisplayable(snapshot.Weekly))
            return new CollapsedSurfacePresentation("本周", snapshot.Weekly.RemainingPercent);
        return new CollapsedSurfacePresentation("额度", null);
    }

    private void ConfigureCollapsed()
    {
        var stack = new StackPanel
        {
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
        };
        _collapsedValue.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        _collapsedLabel.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        _collapsedLabel.Foreground = new SolidColorBrush(Secondary);
        _collapsedLabel.Margin = new Thickness(0, -1, 0, 0);
        stack.Children.Add(_collapsedValue);
        stack.Children.Add(_collapsedLabel);
        _collapsed.Children.Add(stack);
    }

    private void ConfigureExpanded()
    {
        _expanded.RowDefinitions.Add(new RowDefinition());
        _expanded.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        _expanded.RowDefinitions.Add(new RowDefinition());
        AddRow("5h", _fiveHourValue, _fiveHourResetDate, _fiveHourResetTime, 0);

        var divider = new Border
        {
            Height = 1,
            Margin = new Thickness(8, 0, 8, 0),
            Background = new SolidColorBrush(Color.FromArgb(31, 26, 28, 38)),
        };
        Grid.SetRow(divider, 1);
        _expanded.Children.Add(divider);
        AddRow("周", _weeklyValue, _weeklyResetDate, _weeklyResetTime, 2);
    }

    private void AddRow(string title, TextBlock value, TextBlock resetDate, TextBlock resetTime, int row)
    {
        var left = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = System.Windows.VerticalAlignment.Center };
        var titleText = MakeText(10, FontWeights.SemiBold);
        titleText.Text = title;
        titleText.Foreground = new SolidColorBrush(Primary);
        titleText.Width = 21;
        left.Children.Add(titleText);
        left.Children.Add(value);

        var right = new StackPanel
        {
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
        };
        foreach (var text in new[] { resetDate, resetTime })
        {
            text.Foreground = new SolidColorBrush(Secondary);
            text.HorizontalAlignment = System.Windows.HorizontalAlignment.Right;
            text.TextAlignment = TextAlignment.Right;
            right.Children.Add(text);
        }

        var rowGrid = new Grid { Margin = new Thickness(9, 0, 9, 0) };
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(left, 0);
        Grid.SetColumn(right, 1);
        rowGrid.Children.Add(left);
        rowGrid.Children.Add(right);
        Grid.SetRow(rowGrid, row);
        _expanded.Children.Add(rowGrid);
    }

    private void UpdateShape()
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var radius = CornerRadius;
        var corner = new CornerRadius(radius);
        _baseLayer.CornerRadius = corner;
        _colorLayer.CornerRadius = corner;
        Clip = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight), radius, radius);
    }

    private static void SetReset(
        TextBlock date,
        TextBlock time,
        UsageWindow window,
        CultureInfo culture,
        TimeZoneInfo timeZone)
    {
        if (window.Freshness == Freshness.Unavailable || window.ResetsAt is not { } epoch)
        {
            date.Text = "重置";
            time.Text = "不可用";
            return;
        }
        var local = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeSeconds(epoch), timeZone);
        date.Text = local.ToString(window.Kind == UsageWindowKind.Weekly ? "M/d ddd" : "M/d", culture);
        time.Text = local.ToString("HH:mm", culture);
    }

    private static bool IsDisplayable(UsageWindow window) =>
        window.Freshness != Freshness.Unavailable && window.RemainingPercent is not null;

    private static Brush BrushFor(double? value)
    {
        var color = value switch
        {
            null => Secondary,
            < 20 => Color.FromRgb(255, 107, 120),
            < 60 => Color.FromRgb(255, 196, 90),
            _ => Color.FromRgb(69, 224, 138),
        };
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static string FormatPercent(double? value) => value is null ? "--" : $"{Math.Round(value.Value):0}";

    private static TextBlock MakeText(double size, FontWeight weight)
    {
        var text = new TextBlock
        {
            FontFamily = new FontFamily("Segoe UI Variable Text"),
            FontSize = size,
            FontWeight = weight,
            LineHeight = size + 1,
        };
        Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular);
        return text;
    }

    private static ImageSource CreateAuroraTexture()
    {
        const int size = 256;
        var pixels = new byte[size * size * 4];
        var lights = new[]
        {
            new AuroraLight(0.18, 0.18, 0.30, Color.FromRgb(255, 97, 184)),
            new AuroraLight(0.82, 0.18, 0.30, Color.FromRgb(46, 224, 255)),
            new AuroraLight(0.80, 0.82, 0.32, Color.FromRgb(82, 122, 255)),
            new AuroraLight(0.18, 0.80, 0.30, Color.FromRgb(184, 87, 255)),
        };
        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var normalizedX = x / (double)(size - 1);
                var normalizedY = y / (double)(size - 1);
                var totalWeight = 0.0;
                var red = 0.0;
                var green = 0.0;
                var blue = 0.0;
                foreach (var light in lights)
                {
                    var dx = normalizedX - light.X;
                    var dy = normalizedY - light.Y;
                    var distanceSquared = dx * dx + dy * dy;
                    var weight = Math.Exp(-distanceSquared / (2 * light.Spread * light.Spread));
                    totalWeight += weight;
                    red += light.Color.R * weight;
                    green += light.Color.G * weight;
                    blue += light.Color.B * weight;
                }

                var edgeDistance = Math.Sqrt(
                    Math.Pow(normalizedX - 0.5, 2) +
                    Math.Pow(normalizedY - 0.5, 2));
                var edgeLift = 0.94 + 0.06 * Math.Min(edgeDistance / 0.71, 1);
                var offset = (y * size + x) * 4;
                pixels[offset] = (byte)Math.Clamp(blue / totalWeight * edgeLift, 0, 255);
                pixels[offset + 1] = (byte)Math.Clamp(green / totalWeight * edgeLift, 0, 255);
                pixels[offset + 2] = (byte)Math.Clamp(red / totalWeight * edgeLift, 0, 255);
                pixels[offset + 3] = 255;
            }
        }
        var bitmap = new WriteableBitmap(size, size, 96, 96, PixelFormats.Bgra32, null);
        bitmap.WritePixels(new Int32Rect(0, 0, size, size), pixels, size * 4, 0);
        bitmap.Freeze();
        return bitmap;
    }

    private readonly record struct AuroraLight(double X, double Y, double Spread, Color Color);
}

internal readonly record struct CollapsedSurfacePresentation(string Label, double? RemainingPercent);
