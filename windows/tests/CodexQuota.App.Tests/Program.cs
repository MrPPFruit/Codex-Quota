using CodexQuota.App;
using CodexQuota.Core;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Globalization;

var tests = new (string Name, Action Body)[]
{
    ("透明角不参与 hit-test", TransparentCornersPassThrough),
    ("圆泡中心参与 hit-test", BubbleCenterIsInteractive),
    ("圆泡表面不再内缩 5 DIP", BubbleSurfaceFillsWindow),
    ("收起额度选择与 macOS 一致", CollapsedSelectionMatchesMac),
    ("收起与展开表面结构 smoke", OverlaySurfaceRendersExpectedGeometry),
    ("未签名程序不通过 Authenticode", UnsignedExecutableIsRejected),
    ("构建目录不被注册为稳定启动路径", BuildDirectoryIsNotStable),
};
var failures = new List<string>();
foreach (var test in tests)
{
    try { test.Body(); Console.WriteLine($"PASS {test.Name}"); }
    catch (Exception error) { failures.Add($"FAIL {test.Name}: {error.Message}"); }
}
if (failures.Count > 0) { failures.ForEach(Console.Error.WriteLine); return 1; }
Console.WriteLine($"PASS {tests.Length}/{tests.Length}");
return 0;

static void TransparentCornersPassThrough()
{
    Assert(!OverlayWindow.IsInsideRoundedSurface(new System.Windows.Point(5, 5), 52, 52, 26), "top-left corner intercepted input");
}

static void BubbleCenterIsInteractive()
{
    Assert(OverlayWindow.IsInsideRoundedSurface(new System.Windows.Point(26, 26), 52, 52, 26), "bubble center was transparent");
}

static void BubbleSurfaceFillsWindow()
{
    Assert(OverlayWindow.IsInsideRoundedSurface(new System.Windows.Point(2, 26), 52, 52, 26), "full-size bubble retained the old 5 DIP inset");
}

static void CollapsedSelectionMatchesMac()
{
    var five = new UsageWindow(UsageWindowKind.FiveHour, 80, 1, Freshness.Fresh);
    var week = new UsageWindow(UsageWindowKind.Weekly, 62, 2, Freshness.Fresh);
    var unavailableFive = UsageWindow.Unavailable(UsageWindowKind.FiveHour);
    var unavailableWeek = UsageWindow.Unavailable(UsageWindowKind.Weekly);
    var staleResidual = new UsageWindow(UsageWindowKind.FiveHour, 99, 3, Freshness.Unavailable);

    Assert(OverlaySurface.SelectCollapsed(new UsageSnapshot(five, week)) == new CollapsedSurfacePresentation("5h", 80), "five-hour window was not preferred");
    Assert(OverlaySurface.SelectCollapsed(new UsageSnapshot(unavailableFive, week)) == new CollapsedSurfacePresentation("本周", 62), "weekly fallback was not selected");
    Assert(OverlaySurface.SelectCollapsed(new UsageSnapshot(unavailableFive, unavailableWeek)) == new CollapsedSurfacePresentation("额度", null), "fully unavailable state was mislabeled");
    Assert(OverlaySurface.SelectCollapsed(new UsageSnapshot(staleResidual, week)) == new CollapsedSurfacePresentation("本周", 62), "unavailable residual value was displayed");
}

static void OverlaySurfaceRendersExpectedGeometry()
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            var snapshot = new UsageSnapshot(
                new UsageWindow(UsageWindowKind.FiveHour, 80, new DateTimeOffset(2026, 7, 14, 18, 30, 0, TimeSpan.Zero).ToUnixTimeSeconds(), Freshness.Fresh),
                new UsageWindow(UsageWindowKind.Weekly, 82, new DateTimeOffset(2026, 7, 20, 3, 0, 0, TimeSpan.Zero).ToUnixTimeSeconds(), Freshness.Fresh));
            RenderAndValidate(snapshot, false, 52, 52, "collapsed.png");
            RenderAndValidate(snapshot, true, 130, 78, "expanded.png");
        }
        catch (Exception error)
        {
            failure = error;
        }
    });
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start();
    thread.Join();
    if (failure is not null) throw failure;
}

static void RenderAndValidate(UsageSnapshot snapshot, bool expanded, int width, int height, string fileName)
{
    var surface = new OverlaySurface(
        animateColorFlow: false,
        culture: CultureInfo.GetCultureInfo("zh-CN"),
        timeZone: TimeZoneInfo.Utc)
    {
        Width = width,
        Height = height,
    };
    surface.SetBackdropAvailable(true);
    surface.SetFlowAngle(24);
    surface.UpdateSnapshot(snapshot);
    surface.SetExpanded(expanded, animate: false);
    surface.Measure(new System.Windows.Size(width, height));
    surface.Arrange(new Rect(0, 0, width, height));
    surface.UpdateLayout();

    var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
    bitmap.Render(surface);
    var pixels = new byte[width * height * 4];
    bitmap.CopyPixels(pixels, width * 4, 0);
    Assert(pixels[3] == 0, $"{fileName} top-left corner was not transparent");
    var centerAlpha = pixels[((height / 2 * width) + width / 2) * 4 + 3];
    Assert(centerAlpha > 0, $"{fileName} center was transparent");
    Assert(!ContainsDecorativeOutline(surface), $"{fileName} contains a border or drop-shadow effect");

    var directory = Environment.GetEnvironmentVariable("CODEX_QUOTA_UI_CAPTURE_DIR");
    if (string.IsNullOrWhiteSpace(directory)) return;
    Directory.CreateDirectory(directory);
    var encoder = new PngBitmapEncoder();
    encoder.Frames.Add(BitmapFrame.Create(bitmap));
    using var stream = File.Create(Path.Combine(directory, fileName));
    encoder.Save(stream);
}

static bool ContainsDecorativeOutline(DependencyObject node)
{
    if (node is System.Windows.Controls.Border border &&
        (border.BorderThickness != new Thickness(0) || border.Effect is not null)) return true;
    for (var index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++)
    {
        if (ContainsDecorativeOutline(VisualTreeHelper.GetChild(node, index))) return true;
    }
    return false;
}

static void UnsignedExecutableIsRejected()
{
    Assert(!AuthenticodePolicy.TryVerify(Environment.ProcessPath!, out _, out _), "unsigned test executable was trusted");
}

static void BuildDirectoryIsNotStable()
{
    Assert(!new StartupRegistration().CanRegisterCurrentExecutable(), "build directory was accepted as a stable install path");
}

static void Assert(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
