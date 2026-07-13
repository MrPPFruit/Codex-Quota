using CodexQuota.App;
using CodexQuota.Core;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Globalization;
using System.Diagnostics;
using System.IO;

var tests = new (string Name, Action Body)[]
{
    ("透明角不参与 hit-test", TransparentCornersPassThrough),
    ("圆泡中心参与 hit-test", BubbleCenterIsInteractive),
    ("圆泡表面不再内缩 5 DIP", BubbleSurfaceFillsWindow),
    ("收起额度选择与 macOS 一致", CollapsedSelectionMatchesMac),
    ("收起与展开表面结构 smoke", OverlaySurfaceRendersExpectedGeometry),
    ("旋转色场覆盖完整展开表面", AuroraFieldCoversExpandedSurface),
    ("官方桌面宿主发现提示兼容迁移", OfficialHostDiscoveryNamesCoverMigration),
    ("官方包发现按 PFN 过滤并清理句柄", OfficialPackageDiscoveryFiltersAndCleansUp),
    ("presence 只转移选中进程所有权", PresenceTransfersOnlySelectedProcess),
    ("locator 始终释放包进程候选", LocatorAlwaysDisposesPackageProcesses),
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

static void AuroraFieldCoversExpandedSurface()
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            foreach (var dpi in new[] { 96, 144 })
            {
                foreach (var angle in new[] { 0, 24, 45, 90, 135 })
                {
                    RenderAndValidate(
                        UsageSnapshot.Unavailable,
                        true,
                        130,
                        78,
                        $"expanded-unavailable-{dpi}dpi-{angle}.png",
                        angle,
                        assertColorCoverage: true,
                        dpi: dpi);
                }
            }
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

static void OfficialHostDiscoveryNamesCoverMigration()
{
    Assert(WindowsCodexPackageProcesses.DiscoveryNames.SequenceEqual(new[] { "Codex", "ChatGPT" }),
        "official desktop host migration aliases changed unexpectedly");
}

static void OfficialPackageDiscoveryFiltersAndCleansUp()
{
    var accepted = Process.GetProcessById(Environment.ProcessId);
    var acceptedResult = WindowsCodexPackageProcesses.FindOfficial(
        CancellationToken.None,
        name => name == "ChatGPT" ? new[] { accepted } : Array.Empty<Process>(),
        ReadOfficialFamily);
    Assert(acceptedResult.Length == 1 && ReferenceEquals(acceptedResult[0], accepted),
        "ChatGPT process with the exact official PFN was rejected");
    Assert(!IsDisposed(accepted), "accepted process was disposed before ownership transfer");
    acceptedResult[0].Dispose();

    var rejected = Process.GetProcessById(Environment.ProcessId);
    var rejectedResult = WindowsCodexPackageProcesses.FindOfficial(
        CancellationToken.None,
        name => name == "ChatGPT" ? new[] { rejected } : Array.Empty<Process>(),
        ReadWrongFamily);
    Assert(rejectedResult.Length == 0, "wrong PFN was accepted");
    Assert(IsDisposed(rejected), "wrong-PFN process was not disposed");

    var firstAlias = Process.GetProcessById(Environment.ProcessId);
    var duplicateAlias = Process.GetProcessById(Environment.ProcessId);
    var deduplicated = WindowsCodexPackageProcesses.FindOfficial(
        CancellationToken.None,
        name => name == "Codex" ? new[] { firstAlias } : new[] { duplicateAlias },
        ReadOfficialFamily);
    Assert(deduplicated.Length == 1 && ReferenceEquals(deduplicated[0], firstAlias),
        "cross-alias PID was not deduplicated deterministically");
    Assert(IsDisposed(duplicateAlias), "duplicate alias process was not disposed");
    deduplicated[0].Dispose();

    using var cancellation = new CancellationTokenSource();
    var cancelled = Process.GetProcessById(Environment.ProcessId);
    try
    {
        _ = WindowsCodexPackageProcesses.FindOfficial(
            cancellation.Token,
            name =>
            {
                if (name == "Codex") cancellation.Cancel();
                return name == "Codex" ? new[] { cancelled } : Array.Empty<Process>();
            },
            ReadOfficialFamily);
        throw new InvalidOperationException("cancelled discovery unexpectedly returned");
    }
    catch (OperationCanceledException)
    {
        Assert(IsDisposed(cancelled), "cancelled discovery leaked a process handle");
    }

    var faulted = Process.GetProcessById(Environment.ProcessId);
    try
    {
        _ = WindowsCodexPackageProcesses.FindOfficial(
            CancellationToken.None,
            name => name == "Codex" ? new[] { faulted } : Array.Empty<Process>(),
            ThrowingFamilyReader);
        throw new InvalidOperationException("faulted discovery unexpectedly returned");
    }
    catch (IOException)
    {
        Assert(IsDisposed(faulted), "faulted discovery leaked a process handle");
    }
}

static void PresenceTransfersOnlySelectedProcess()
{
    var selected = Process.GetProcessById(Environment.ProcessId);
    var unselected = Process.GetProcessById(Environment.ProcessId);
    var probe = new WindowsCodexProcessProbe(
        new BoundedDiagnosticLog(),
        _ => new[] { selected, unselected });
    var observed = probe.FindRunningAsync(CancellationToken.None).AsTask().GetAwaiter().GetResult();
    Assert(observed is not null, "presence did not return the selected process");
    Assert(!IsDisposed(selected), "selected process was disposed before observer ownership");
    Assert(IsDisposed(unselected), "unselected process was not disposed");
    observed!.Dispose();
    Assert(IsDisposed(selected), "observer did not dispose the selected process");
}

static void LocatorAlwaysDisposesPackageProcesses()
{
    var first = Process.GetProcessById(Environment.ProcessId);
    var second = Process.GetProcessById(Environment.ProcessId);
    var locator = new WindowsCodexExecutableLocator(
        new BoundedDiagnosticLog(),
        _ => new[] { first, second });
    var result = locator.LocateAsync(CancellationToken.None).GetAwaiter().GetResult();
    Assert(result is null, "unpackaged test process unexpectedly produced a helper");
    Assert(IsDisposed(first) && IsDisposed(second), "locator leaked package process handles");
}

static bool ReadOfficialFamily(int _, out string? familyName)
{
    familyName = CodexPackagePolicy.OfficialFamilyName;
    return true;
}

static bool ReadWrongFamily(int _, out string? familyName)
{
    familyName = "OpenAI.Codex_2p2nqsd0c76g0.fake";
    return true;
}

static bool ThrowingFamilyReader(int _, out string? familyName)
{
    familyName = null;
    throw new IOException("injected family reader failure");
}

static bool IsDisposed(Process process)
{
    try
    {
        _ = process.Handle;
        return false;
    }
    catch (InvalidOperationException)
    {
        return true;
    }
}

static void RenderAndValidate(
    UsageSnapshot snapshot,
    bool expanded,
    int width,
    int height,
    string fileName,
    double flowAngle = 24,
    bool assertColorCoverage = false,
    double dpi = 96)
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
    surface.SetFlowAngle(flowAngle);
    surface.UpdateSnapshot(snapshot);
    surface.SetExpanded(expanded, animate: false);
    surface.Measure(new System.Windows.Size(width, height));
    surface.Arrange(new Rect(0, 0, width, height));
    surface.UpdateLayout();

    var pixelWidth = (int)Math.Ceiling(width * dpi / 96);
    var pixelHeight = (int)Math.Ceiling(height * dpi / 96);
    var bitmap = new RenderTargetBitmap(pixelWidth, pixelHeight, dpi, dpi, PixelFormats.Pbgra32);
    bitmap.Render(surface);
    var pixels = new byte[pixelWidth * pixelHeight * 4];
    bitmap.CopyPixels(pixels, pixelWidth * 4, 0);
    Assert(pixels[3] == 0, $"{fileName} top-left corner was not transparent");
    var centerAlpha = pixels[((pixelHeight / 2 * pixelWidth) + pixelWidth / 2) * 4 + 3];
    Assert(centerAlpha > 0, $"{fileName} center was transparent");
    Assert(!ContainsDecorativeOutline(surface), $"{fileName} contains a border or drop-shadow effect");
    if (assertColorCoverage)
    {
        foreach (var point in new[]
        {
            new System.Windows.Point(12, 12),
            new System.Windows.Point(width - 12, 12),
            new System.Windows.Point(12, height - 12),
            new System.Windows.Point(width - 12, height - 12),
            new System.Windows.Point(2, height / 2),
            new System.Windows.Point(width - 2, height / 2),
            new System.Windows.Point(width / 2, 2),
            new System.Windows.Point(width / 2, height - 2),
        })
        {
            var pixelX = (int)Math.Round(point.X * dpi / 96);
            var pixelY = (int)Math.Round(point.Y * dpi / 96);
            var offset = ((pixelY * pixelWidth) + pixelX) * 4;
            Assert(pixels[offset + 3] > 200,
                $"{fileName} color field did not cover ({point.X}, {point.Y})");
        }
    }

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
