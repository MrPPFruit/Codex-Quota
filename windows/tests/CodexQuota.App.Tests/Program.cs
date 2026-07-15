using CodexQuota.App;
using CodexQuota.Core;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Globalization;
using System.Diagnostics;
using System.IO;
using System.Collections.Concurrent;
using System.Text.Json;

if (args is ["app-server", "--stdio"])
{
    return RunFakeAppServer();
}

if (args is ["--owned-process-test-child"])
{
    Thread.Sleep(Timeout.Infinite);
    return 0;
}

var tests = new (string Name, Action Body)[]
{
    ("透明角不参与 hit-test", TransparentCornersPassThrough),
    ("圆泡中心参与 hit-test", BubbleCenterIsInteractive),
    ("圆泡表面不再内缩 5 DIP", BubbleSurfaceFillsWindow),
    ("菜单状态区分显示偏好与 Codex 在线状态", OverlayMenuStateMatchesVisibilityPreference),
    ("启动项不可用时提示固定安装路径", StartupMenuPresentationExplainsFixedInstallRequirement),
    ("小球右键事件只请求一次共享菜单", BubbleRightClickRequestsSharedMenu),
    ("收起额度选择与 macOS 一致", CollapsedSelectionMatchesMac),
    ("展开排版使用 Win10 稳定字体与安全边距", ExpandedTypographyAndInsetsMatchWindows),
    ("收起与展开表面结构 smoke", OverlaySurfaceRendersExpectedGeometry),
    ("旋转色场覆盖完整展开表面", AuroraFieldCoversExpandedSurface),
    ("柔雾色场匹配 macOS 色相与中心漫射", SoftAuroraMatchesMacPalette),
    ("Win10 使用逐像素透明圆角且 Win11 保留 Acrylic", WindowsCompositionModeMatchesPlatform),
    ("官方桌面宿主发现提示兼容迁移", OfficialHostDiscoveryNamesCoverMigration),
    ("官方包发现按 PFN 过滤并清理句柄", OfficialPackageDiscoveryFiltersAndCleansUp),
    ("presence 只转移选中进程所有权", PresenceTransfersOnlySelectedProcess),
    ("locator 始终释放包进程候选", LocatorAlwaysDisposesPackageProcesses),
    ("locator 使用系统包根与官方运行副本", LocatorUsesPackageRootAndOfficialRuntimeCopy),
    ("locator 拒绝不同内容与包根逃逸", LocatorRejectsHashMismatchAndHostEscape),
    ("跨磁盘包根路径判断不依赖系统盘", PackageRootContainmentSupportsOtherVolumes),
    ("app-server 初始化后释放执行 lease", ClientReleasesExecutionLeaseAfterInitialize),
    ("app-server 无推送时周期校准额度", ClientCalibratesWithoutPush),
    ("校准失败清空旧额度并拒绝局部更新", ClearingPayloadPreventsStalePartialUpdate),
    ("app-server 并发第二次启动被拒绝", ClientRejectsConcurrentSecondStart),
    ("自有子进程在期限内按原句柄退出", OwnedProcessStopsWithinDeadline),
    ("app-server 并发释放共享同一清理任务", ClientDisposeIsIdempotent),
    ("session 快速启停串行清理并隔离旧代际", SessionTransitionsAreSerialized),
    ("session 回调与失效发布保持原子顺序", SessionPublicationAndInvalidationAreSerialized),
    ("session 正常断线发布不可用并退避", SessionCompletionBacksOff),
    ("session 未知编程异常不进入重试", UnknownSessionFailureDoesNotRetry),
    ("session 清理异常不破坏最终缺席状态", SessionCleanupFailureStillPublishesAbsent),
    ("session 退出未确认时阻止重连", UnconfirmedCleanupBlocksRestart),
    ("未签名程序不通过 Authenticode", UnsignedExecutableIsRejected),
    ("构建目录不被注册为稳定启动路径", BuildDirectoryIsNotStable),
    ("发布脚本支持独立恢复与 CI 跳过恢复", ReleaseScriptDeclaresRestoreContract),
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

static void OverlayMenuStateMatchesVisibilityPreference()
{
    var runningVisible = new OverlayMenuState(CodexPresent: true, VisibilityEnabled: true);
    var runningHidden = new OverlayMenuState(CodexPresent: true, VisibilityEnabled: false);
    var waitingVisible = new OverlayMenuState(CodexPresent: false, VisibilityEnabled: true);
    var waitingHidden = new OverlayMenuState(CodexPresent: false, VisibilityEnabled: false);

    Assert(runningVisible.VisibilityTitle == "显示额度小球" && runningVisible.VisibilityEnabled,
        "running visible preference was not presented as selected");
    Assert(runningHidden.VisibilityTitle == "显示额度小球" && !runningHidden.VisibilityEnabled,
        "running hidden preference was not presented as unselected");
    Assert(waitingVisible.VisibilityTitle == "Codex 启动后显示小球" && waitingVisible.VisibilityEnabled,
        "waiting visible preference lost its future-display selection");
    Assert(waitingHidden.VisibilityTitle == "Codex 启动后显示小球" && !waitingHidden.VisibilityEnabled,
        "waiting hidden preference was not presented as unselected");
}

static void StartupMenuPresentationExplainsFixedInstallRequirement()
{
    var unsupported = StartupMenuPresentation.Create(canRegister: false, isRegistered: false);
    var supported = StartupMenuPresentation.Create(canRegister: true, isRegistered: true);
    var movedAfterRegistration = StartupMenuPresentation.Create(canRegister: false, isRegistered: true);

    Assert(!unsupported.IsEnabled && !unsupported.IsChecked,
        "unstable install path left the startup action enabled or selected");
    Assert(unsupported.Title == "登录 Windows 时启动（需固定安装）",
        "unstable install path did not explain why startup is unavailable");
    Assert(unsupported.ToolTipText.Contains("%LOCALAPPDATA%\\Programs\\Codex Quota", StringComparison.Ordinal),
        "startup recovery path was not shown");
    Assert(supported.IsEnabled && supported.IsChecked && supported.Title == "登录 Windows 时启动",
        "stable registered install lost its normal startup presentation");
    Assert(movedAfterRegistration.IsEnabled && movedAfterRegistration.IsChecked,
        "existing startup registration could no longer be turned off after the executable moved");
}

static void BubbleRightClickRequestsSharedMenu()
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            var requestCount = 0;
            var window = new OverlayWindow(
                compositionMode: OverlayCompositionMode.PerPixelAlpha,
                showContextMenu: () => requestCount++);
            var mouseUp = new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Right)
            {
                RoutedEvent = Mouse.PreviewMouseUpEvent,
                Source = window,
            };

            window.RaiseEvent(mouseUp);

            Assert(requestCount == 1, $"right-click requested the menu {requestCount} times");
            Assert(mouseUp.Handled, "right-click continued into another input route");
            window.Close();
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
            RenderAndValidate(snapshot, false, 52, 52, "collapsed-win10.png", backdropAvailable: false);
            RenderAndValidate(snapshot, true, 130, 78, "expanded-win10.png", backdropAvailable: false);
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
            foreach (var dpi in new[] { 96, 120, 144, 192 })
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

static void ExpandedTypographyAndInsetsMatchWindows()
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            var snapshot = new UsageSnapshot(
                new UsageWindow(UsageWindowKind.FiveHour, 80, new DateTimeOffset(2026, 7, 22, 4, 37, 0, TimeSpan.Zero).ToUnixTimeSeconds(), Freshness.Fresh),
                new UsageWindow(UsageWindowKind.Weekly, 100, new DateTimeOffset(2026, 7, 22, 4, 37, 0, TimeSpan.Zero).ToUnixTimeSeconds(), Freshness.Fresh));
            var surface = new OverlaySurface(
                animateColorFlow: false,
                culture: CultureInfo.GetCultureInfo("zh-CN"),
                timeZone: TimeZoneInfo.Utc)
            {
                Width = 130,
                Height = 78,
            };
            surface.UpdateSnapshot(snapshot);
            surface.SetExpanded(true, animate: false);
            surface.Measure(new System.Windows.Size(130, 78));
            surface.Arrange(new Rect(0, 0, 130, 78));
            surface.UpdateLayout();

            var text = Descendants<TextBlock>(surface).ToArray();
            var fiveHourTitle = text.Single(item => item.Text == "5h" && item.FontSize == 10);
            var fiveHourValue = text.Single(item => item.Text == "80" && item.FontSize == 14);
            var resetDate = text.Single(item => item.Text == "7/22");
            var weeklyTitle = text.Single(item => item.Text == "周" && item.FontSize == 10);
            var weeklyValue = text.Single(item => item.Text == "100");
            var weeklyResetDate = text.Single(item => item.Text.Contains("周三", StringComparison.Ordinal));
            var resetTimes = text.Where(item => item.Text == "04:37").ToArray();
            Assert(resetTimes.Length == 2, "both reset times were not rendered");
            var resetTime = resetTimes[0];
            foreach (var label in new[] { fiveHourTitle, resetDate, resetTime, weeklyTitle, weeklyResetDate })
            {
                Assert(label.FontFamily.Source == "Segoe UI",
                    $"{label.Text} resolved to non-Win10 UI font {label.FontFamily.Source}");
            }

            var titleBounds = BoundsIn(fiveHourTitle, surface);
            var valueBounds = BoundsIn(fiveHourValue, surface);
            var dateBounds = BoundsIn(resetDate, surface);
            var timeBounds = BoundsIn(resetTime, surface);
            var weeklyTitleBounds = BoundsIn(weeklyTitle, surface);
            var weeklyValueBounds = BoundsIn(weeklyValue, surface);
            var weeklyDateBounds = BoundsIn(weeklyResetDate, surface);
            Assert(titleBounds.Left >= 12, $"left content inset was only {titleBounds.Left:0.##} DIP");
            Assert(weeklyTitleBounds.Left >= 12, $"weekly left content inset was only {weeklyTitleBounds.Left:0.##} DIP");
            var rightmost = new[] { dateBounds.Right, timeBounds.Right, weeklyDateBounds.Right }.Max();
            Assert(rightmost <= 118,
                $"right content exceeded the 12 DIP safe inset ({rightmost:0.##})");
            Assert(valueBounds.Left - titleBounds.Right >= 4,
                $"title-to-value gap was only {valueBounds.Left - titleBounds.Right:0.##} DIP");
            Assert(weeklyValueBounds.Left - weeklyTitleBounds.Right >= 4,
                $"weekly title-to-value gap was only {weeklyValueBounds.Left - weeklyTitleBounds.Right:0.##} DIP");
            Assert(weeklyDateBounds.Left - weeklyValueBounds.Right >= 6,
                $"weekly value-to-reset gap was only {weeklyDateBounds.Left - weeklyValueBounds.Right:0.##} DIP");
            Assert(fiveHourValue.MinWidth >= 30, "quota value lost its stable 30 DIP measure");
            Assert(weeklyValue.MinWidth >= 30, "three-digit weekly quota lost its stable 30 DIP measure");
            foreach (var dpi in new[] { 120.0, 144.0 })
            {
                RenderAndValidate(
                    snapshot,
                    true,
                    130,
                    78,
                    $"expanded-long-content-{dpi:0}dpi.png",
                    dpi: dpi,
                    backdropAvailable: false);
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

static void SoftAuroraMatchesMacPalette()
{
    const int size = 129;
    var first = OverlaySurface.CreateSoftAuroraPixels(size);
    var second = OverlaySurface.CreateSoftAuroraPixels(size);
    Assert(first.SequenceEqual(second), "soft aurora generation was not deterministic");
    Assert(first.Length == size * size * 4, "soft aurora pixel buffer has the wrong size");

    var center = ReadPixel(first, size, 64, 64);
    var right = ReadPixel(first, size, 112, 64);
    var bottom = ReadPixel(first, size, 64, 112);
    var left = ReadPixel(first, size, 16, 64);
    var top = ReadPixel(first, size, 64, 16);

    Assert(new[] { center, right, bottom, left, top }.All(pixel => pixel.A == byte.MaxValue),
        "soft aurora contains transparent texture pixels");
    Assert(right.G > right.R + 80 && right.B > right.R + 100, "right-side cyan was lost");
    Assert(bottom.B > bottom.R + 80 && bottom.B > bottom.G + 50, "bottom-side blue was lost");
    Assert(left.R > left.G + 70 && left.B > left.G + 90, "left-side purple was lost");
    Assert(top.R > top.G + 100 && top.B > top.G + 40, "top-side pink was lost");
    var outerLuminance = new[] { right, bottom, left, top }.Average(Luminance);
    Assert(Luminance(center) > outerLuminance, "center diffuse light was not brighter than the outer field");

    var maximumCenterStep = 0.0;
    for (var y = 56; y <= 72; y++)
    {
        for (var x = 56; x < 72; x++)
        {
            maximumCenterStep = Math.Max(maximumCenterStep,
                ColorDistance(ReadPixel(first, size, x, y), ReadPixel(first, size, x + 1, y)));
            maximumCenterStep = Math.Max(maximumCenterStep,
                ColorDistance(ReadPixel(first, size, y, x), ReadPixel(first, size, y, x + 1)));
        }
    }
    Assert(maximumCenterStep < 55, $"soft aurora retained a hard center sector ({maximumCenterStep:0.0})");
}

static void WindowsCompositionModeMatchesPlatform()
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            var windows10 = OverlayWindow.SelectCompositionMode(new Version(10, 0, 19045));
            var windows11 = OverlayWindow.SelectCompositionMode(new Version(10, 0, 22621));
            Assert(windows10 == OverlayCompositionMode.PerPixelAlpha,
                "Windows 10 retained the 1-bit native window region");
            Assert(windows11 == OverlayCompositionMode.DesktopAcrylic,
                "Windows 11 lost the Desktop Acrylic path");

            var layered = new OverlayWindow(compositionMode: windows10);
            var acrylic = new OverlayWindow(compositionMode: windows11);
            Assert(layered.AllowsTransparency, "Windows 10 did not enable per-pixel alpha");
            Assert(!acrylic.AllowsTransparency, "Windows 11 Acrylic was placed on a layered window");
            layered.Close();
            acrylic.Close();
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

static (byte R, byte G, byte B, byte A) ReadPixel(byte[] pixels, int size, int x, int y)
{
    var offset = (y * size + x) * 4;
    return (pixels[offset + 2], pixels[offset + 1], pixels[offset], pixels[offset + 3]);
}

static double Luminance((byte R, byte G, byte B, byte A) pixel) =>
    pixel.R * 0.2126 + pixel.G * 0.7152 + pixel.B * 0.0722;

static double ColorDistance((byte R, byte G, byte B, byte A) first, (byte R, byte G, byte B, byte A) second) =>
    Math.Sqrt(
        Math.Pow(first.R - second.R, 2) +
        Math.Pow(first.G - second.G, 2) +
        Math.Pow(first.B - second.B, 2));

static void LocatorUsesPackageRootAndOfficialRuntimeCopy()
{
    var root = CreateTestRoot();
    try
    {
        var packageRoot = Path.Combine(root, "另一个磁盘 Package Root");
        var packageHelper = Path.Combine(packageRoot, "app", "resources", "codex.exe");
        var localAppData = Path.Combine(root, "重定向 Local AppData");
        var runtime = Path.Combine(localAppData, "OpenAI", "Codex", "bin", "version-a", "codex.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(packageHelper)!);
        Directory.CreateDirectory(Path.GetDirectoryName(runtime)!);
        var content = new byte[] { 1, 3, 3, 7, 42 };
        File.WriteAllBytes(packageHelper, content);
        File.WriteAllBytes(runtime, content);

        var process = Process.GetProcessById(Environment.ProcessId);
        var probeSawLockedCandidate = false;
        var locator = new WindowsCodexExecutableLocator(
            new BoundedDiagnosticLog(),
            _ => new[] { process },
            ReadIdentity,
            _ => Path.Combine(packageRoot, "app", "ChatGPT.exe"),
            path => path == packageHelper ? new AuthenticodeIdentity("OpenAI test signer", "AA") : null,
            (path, _) =>
            {
                try
                {
                    using var write = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite);
                }
                catch (IOException)
                {
                    probeSawLockedCandidate = true;
                }
                return Task.FromResult(probeSawLockedCandidate);
            },
            localAppData);

        var accepted = locator.LocateAsync(CancellationToken.None).GetAwaiter().GetResult();
        Assert(accepted?.Path == runtime, "official runtime copy was not accepted");
        Assert(probeSawLockedCandidate, "capability probe ran without the execution lease");
        Assert(IsDisposed(process), "locator did not release the package process");
        AssertThrows<IOException>(() => File.Delete(runtime), "accepted runtime was replaceable before lease transfer");
        accepted!.Dispose();
        File.Delete(runtime);
        Assert(!File.Exists(runtime), "execution lease remained after candidate disposal");

        bool ReadIdentity(int _, out OfficialCodexPackageIdentity? identity)
        {
            identity = new OfficialCodexPackageIdentity(
                CodexPackagePolicy.OfficialFamilyName,
                "OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0",
                packageRoot);
            return true;
        }
    }
    finally
    {
        DeleteTestRoot(root);
    }
}

static void LocatorRejectsHashMismatchAndHostEscape()
{
    var root = CreateTestRoot();
    try
    {
        var packageRoot = Path.Combine(root, "package");
        var packageHelper = Path.Combine(packageRoot, "app", "resources", "codex.exe");
        var localAppData = Path.Combine(root, "local");
        var runtime = Path.Combine(localAppData, "OpenAI", "Codex", "bin", "version-a", "codex.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(packageHelper)!);
        Directory.CreateDirectory(Path.GetDirectoryName(runtime)!);
        File.WriteAllBytes(packageHelper, new byte[] { 1, 2, 3 });
        File.WriteAllBytes(runtime, new byte[] { 1, 2, 4 });

        var probeCount = 0;
        var mismatchProcess = Process.GetProcessById(Environment.ProcessId);
        var mismatchLocator = CreateLocator(mismatchProcess, Path.Combine(packageRoot, "app", "ChatGPT.exe"));
        Assert(mismatchLocator.LocateAsync(CancellationToken.None).GetAwaiter().GetResult() is null,
            "different runtime content was accepted");
        Assert(probeCount == 0, "hash mismatch reached capability probe");
        Assert(IsDisposed(mismatchProcess), "hash-mismatch package process leaked");

        File.WriteAllBytes(runtime, new byte[] { 1, 2, 3 });
        var escapedProcess = Process.GetProcessById(Environment.ProcessId);
        var escapedLocator = CreateLocator(escapedProcess, Path.Combine(root, "outside", "ChatGPT.exe"));
        Assert(escapedLocator.LocateAsync(CancellationToken.None).GetAwaiter().GetResult() is null,
            "host outside system package root was accepted");
        Assert(probeCount == 0, "escaped host reached helper probe");
        Assert(IsDisposed(escapedProcess), "escaped-host package process leaked");

        WindowsCodexExecutableLocator CreateLocator(Process process, string hostPath) =>
            new(
                new BoundedDiagnosticLog(),
                _ => new[] { process },
                ReadIdentity,
                _ => hostPath,
                path => path == packageHelper ? new AuthenticodeIdentity("OpenAI test signer", "AA") : null,
                (_, _) =>
                {
                    probeCount++;
                    return Task.FromResult(true);
                },
                localAppData);

        bool ReadIdentity(int _, out OfficialCodexPackageIdentity? identity)
        {
            identity = new OfficialCodexPackageIdentity(
                CodexPackagePolicy.OfficialFamilyName,
                "OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0",
                packageRoot);
            return true;
        }
    }
    finally
    {
        DeleteTestRoot(root);
    }
}

static void PackageRootContainmentSupportsOtherVolumes()
{
    Assert(WindowsCodexExecutableLocator.IsPathWithinRoot(
            @"D:\Program Files\WindowsApps\OpenAI.Codex_1_x64__publisher",
            @"D:\Program Files\WindowsApps\OpenAI.Codex_1_x64__publisher\app\ChatGPT.exe"),
        "non-system-volume package path was rejected");
    Assert(!WindowsCodexExecutableLocator.IsPathWithinRoot(
            @"D:\Program Files\WindowsApps\OpenAI.Codex_1_x64__publisher",
            @"C:\Program Files\WindowsApps\OpenAI.Codex_1_x64__publisher\app\ChatGPT.exe"),
        "different-volume host escaped the package root");
    Assert(!WindowsCodexExecutableLocator.IsPathWithinRoot(@"D:\package", @"D:\package-escape\app.exe"),
        "prefix sibling escaped the package root");
}

static void ClientReleasesExecutionLeaseAfterInitialize()
{
    var lease = new TrackingDisposable();
    var candidate = new CodexExecutableCandidate(
        Environment.ProcessPath ?? throw new InvalidOperationException("test executable unavailable"),
        "test",
        lease);
    var client = new CodexAppServerClient(candidate, new BoundedDiagnosticLog());
    var snapshot = client.StartAsync(CancellationToken.None).GetAwaiter().GetResult();
    Assert(snapshot.FiveHour.RemainingPercent == 93, "fake app-server did not initialize");
    Assert(lease.DisposeCount == 1, "execution lease was not released after initialize and first snapshot");
    client.DisposeAsync().AsTask().GetAwaiter().GetResult();
    Assert(lease.DisposeCount == 1, "execution lease was released more than once");
}

static void ClientCalibratesWithoutPush()
{
    const string sequenceVariable = "CODEX_QUOTA_TEST_RATE_LIMIT_USED_SEQUENCE";
    var originalSequence = Environment.GetEnvironmentVariable(sequenceVariable);
    Environment.SetEnvironmentVariable(sequenceVariable, "7,44");
    var snapshots = new ConcurrentQueue<UsageSnapshot>();
    var client = new CodexAppServerClient(
        new CodexExecutableCandidate(
            Environment.ProcessPath ?? throw new InvalidOperationException("test executable unavailable"),
            "test"),
        new BoundedDiagnosticLog(),
        calibrationInterval: TimeSpan.FromMilliseconds(25));
    client.SnapshotChanged += snapshots.Enqueue;
    try
    {
        var initial = client.StartAsync(CancellationToken.None).GetAwaiter().GetResult();
        Assert(initial.FiveHour.RemainingPercent == 93, "initial fake rate-limit snapshot was not received");
        Assert(SpinWait.SpinUntil(
                () => snapshots.Any(snapshot => snapshot.FiveHour.RemainingPercent == 56),
                TimeSpan.FromSeconds(2)),
            "rate limit remained at the initial snapshot when no update push arrived");
    }
    finally
    {
        client.DisposeAsync().AsTask().GetAwaiter().GetResult();
        Environment.SetEnvironmentVariable(sequenceVariable, originalSequence);
    }
}

static void ClearingPayloadPreventsStalePartialUpdate()
{
    var state = new UsagePayloadState();
    var payload = new RateLimitPayload(
        new RateLimitWindow(7, 300, 1783987200),
        new RateLimitWindow(22, 10080, 1784505600),
        []);
    Assert(state.TryCommitFull(0, payload, out _), "test payload was not committed");

    UsageSnapshot? cleared = null;
    state.ClearAndPublish(snapshot => cleared = snapshot);

    var patch = new RateLimitPatch(
        FieldPatch<RateLimitWindowPatch>.FromValue(new RateLimitWindowPatch(
            FieldPatch<double>.FromValue(44),
            FieldPatch<int>.Missing,
            FieldPatch<long>.Missing)),
        FieldPatch<RateLimitWindowPatch>.Missing);
    var result = state.Apply(patch);

    Assert(cleared == UsageSnapshot.Unavailable, "calibration failure did not publish unavailable state");
    Assert(result.RequiresFullRefresh && result.Snapshot is null,
        "partial update reused the payload that calibration had invalidated");
}

static void ClientRejectsConcurrentSecondStart()
{
    const string lifetimeVariable = "CODEX_QUOTA_TEST_CHILD_MAX_LIFETIME_MS";
    var originalLifetime = Environment.GetEnvironmentVariable(lifetimeVariable);
    Environment.SetEnvironmentVariable(lifetimeVariable, "2000");
    var executableName = Path.GetFileNameWithoutExtension(Environment.ProcessPath)
        ?? throw new InvalidOperationException("test executable name unavailable");
    var baselineProcesses = CountProcessesByName(executableName);
    var client = new CodexAppServerClient(
        Environment.ProcessPath ?? throw new InvalidOperationException("test executable unavailable"),
        new BoundedDiagnosticLog());
    var rejected = false;
    var observedProcesses = baselineProcesses;
    try
    {
        var firstStart = client.StartAsync(CancellationToken.None);
        try
        {
            _ = client.StartAsync(CancellationToken.None).GetAwaiter().GetResult();
        }
        catch (InvalidOperationException)
        {
            rejected = true;
        }

        _ = firstStart.GetAwaiter().GetResult();
        observedProcesses = CountProcessesByName(executableName);
    }
    finally
    {
        client.DisposeAsync().AsTask().GetAwaiter().GetResult();
        Environment.SetEnvironmentVariable(lifetimeVariable, originalLifetime);
    }

    Assert(rejected, "a concurrent second StartAsync call was accepted");
    Assert(observedProcesses - baselineProcesses == 1, "more than one app-server child was created");
}

static void OwnedProcessStopsWithinDeadline()
{
    var executable = Environment.ProcessPath ?? throw new InvalidOperationException("test executable unavailable");
    using var process = new Process
    {
        StartInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
        },
    };
    process.StartInfo.ArgumentList.Add("--owned-process-test-child");
    Assert(process.Start(), "owned child did not start");
    var ownedProcessId = process.Id;
    var stopwatch = Stopwatch.StartNew();

    var confirmed = OwnedProcessShutdown.StopAsync(process, closeStandardInput: false)
        .GetAwaiter().GetResult();

    Assert(confirmed, "owned child exit was not confirmed");
    Assert(process.HasExited, "owned child remained alive");
    Assert(process.Id == ownedProcessId, "shutdown no longer referred to the originally owned process");
    Assert(stopwatch.Elapsed < TimeSpan.FromSeconds(3), "owned child shutdown exceeded the total deadline");
}

static void ClientDisposeIsIdempotent()
{
    var client = new CodexAppServerClient("unused", new BoundedDiagnosticLog());
    var first = client.DisposeAsync().AsTask();
    var second = client.DisposeAsync().AsTask();

    Assert(ReferenceEquals(first, second), "concurrent dispose calls did not share cleanup ownership");
    Task.WhenAll(first, second).GetAwaiter().GetResult();
}

static void SessionTransitionsAreSerialized()
{
    var disposeRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var first = new FakeUsageSession(() => disposeRelease.Task);
    var second = new FakeUsageSession();
    var sessions = new Queue<FakeUsageSession>([first, second]);
    var publications = new ConcurrentQueue<(bool Present, UsageSnapshot Snapshot)>();
    var coordinator = CreateCoordinator(sessions, publications);

    coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    Assert(first.StartCount == 1, "first session did not start");

    var stop = coordinator.PresenceChangedAsync(false, CancellationToken.None).AsTask();
    first.DisposeStarted.Task.WaitAsync(TimeSpan.FromSeconds(1)).GetAwaiter().GetResult();
    var restart = coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask();
    Assert(!restart.IsCompleted, "restart bypassed in-flight cleanup");
    Assert(second.StartCount == 0, "second session overlapped first-session cleanup");

    disposeRelease.TrySetResult();
    Task.WhenAll(stop, restart).GetAwaiter().GetResult();
    Assert(first.DisposeCount == 1, "first session was not disposed exactly once");
    Assert(second.StartCount == 1, "second session did not start after cleanup");

    var publicationCount = publications.Count;
    first.PublishAfterRemoval(new UsageSnapshot(
        new UsageWindow(UsageWindowKind.FiveHour, 1, 1, Freshness.Fresh),
        UsageWindow.Unavailable(UsageWindowKind.Weekly)));
    Assert(publications.Count == publicationCount, "old generation published after restart");

    coordinator.PresenceChangedAsync(false, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
}

static void SessionPublicationAndInvalidationAreSerialized()
{
    var session = new FakeUsageSession();
    var sessions = new Queue<FakeUsageSession>([session]);
    var publications = new ConcurrentQueue<(bool Present, UsageSnapshot Snapshot)>();
    using var publicationEntered = new ManualResetEventSlim();
    using var publicationRelease = new ManualResetEventSlim();
    var lateSnapshot = new UsageSnapshot(
        new UsageWindow(UsageWindowKind.FiveHour, 42, 1, Freshness.Fresh),
        UsageWindow.Unavailable(UsageWindowKind.Weekly));
    var coordinator = new UsageSessionCoordinator(
        _ => Task.FromResult<CodexExecutableCandidate?>(new CodexExecutableCandidate("test-helper", "test")),
        _ => sessions.Dequeue(),
        new BoundedDiagnosticLog(),
        (present, snapshot) =>
        {
            if (snapshot == lateSnapshot)
            {
                publicationEntered.Set();
                publicationRelease.Wait();
            }
            publications.Enqueue((present, snapshot));
        },
        (_, cancellationToken) => Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken));

    coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    var latePublish = Task.Run(() => session.PublishCurrent(lateSnapshot));
    Assert(publicationEntered.Wait(TimeSpan.FromSeconds(1)), "late publication did not enter callback");
    var stop = Task.Run(() => coordinator.PresenceChangedAsync(false, CancellationToken.None).AsTask());
    _ = stop.Wait(TimeSpan.FromMilliseconds(200));
    publicationRelease.Set();
    Task.WhenAll(latePublish, stop).GetAwaiter().GetResult();

    var final = publications.Last();
    Assert(!final.Present && final.Snapshot == UsageSnapshot.Unavailable,
        "late generation callback overwrote final absent state");
    coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
}

static void SessionCompletionBacksOff()
{
    var first = new FakeUsageSession();
    var second = new FakeUsageSession();
    var sessions = new Queue<FakeUsageSession>([first, second]);
    var publications = new ConcurrentQueue<(bool Present, UsageSnapshot Snapshot)>();
    var backoffEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var coordinator = new UsageSessionCoordinator(
        _ => Task.FromResult<CodexExecutableCandidate?>(new CodexExecutableCandidate("test-helper", "test")),
        _ => sessions.Dequeue(),
        new BoundedDiagnosticLog(),
        (present, snapshot) => publications.Enqueue((present, snapshot)),
        (_, cancellationToken) =>
        {
            backoffEntered.TrySetResult();
            return Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        });
    var fresh = new UsageSnapshot(
        new UsageWindow(UsageWindowKind.FiveHour, 75, 1, Freshness.Fresh),
        UsageWindow.Unavailable(UsageWindowKind.Weekly));

    coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    first.PublishCurrent(fresh);
    first.Complete();
    backoffEntered.Task.WaitAsync(TimeSpan.FromSeconds(1)).GetAwaiter().GetResult();

    Assert(second.StartCount == 0, "normal disconnect retried without backoff");
    Assert(publications.Last().Snapshot == UsageSnapshot.Unavailable,
        "normal disconnect did not publish unavailable before backoff");
    coordinator.PresenceChangedAsync(false, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
}

static void UnknownSessionFailureDoesNotRetry()
{
    var locatorCalls = 0;
    var factoryCalls = 0;
    var delayCalls = 0;
    var candidateLease = new TrackingDisposable();
    var factoryEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var coordinator = new UsageSessionCoordinator(
        _ =>
        {
            Interlocked.Increment(ref locatorCalls);
            return Task.FromResult<CodexExecutableCandidate?>(
                new CodexExecutableCandidate("test-helper", "test", candidateLease));
        },
        _ =>
        {
            Interlocked.Increment(ref factoryCalls);
            factoryEntered.TrySetResult();
            throw new ApplicationException("injected programming failure");
        },
        new BoundedDiagnosticLog(),
        (_, _) => { },
        (_, cancellationToken) =>
        {
            Interlocked.Increment(ref delayCalls);
            return Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        });

    coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    factoryEntered.Task.WaitAsync(TimeSpan.FromSeconds(1)).GetAwaiter().GetResult();
    Assert(SpinWait.SpinUntil(() => candidateLease.DisposeCount == 1, TimeSpan.FromSeconds(1)),
        "candidate lease was not released after factory failure");
    _ = SpinWait.SpinUntil(() => Volatile.Read(ref delayCalls) != 0, TimeSpan.FromMilliseconds(200));

    Assert(delayCalls == 0, "unknown programming failure entered retry backoff");
    Assert(locatorCalls == 1 && factoryCalls == 1, "unknown programming failure restarted the session");
    coordinator.PresenceChangedAsync(false, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
}

static void SessionCleanupFailureStillPublishesAbsent()
{
    var failing = new FakeUsageSession(() => Task.FromException(new IOException("injected cleanup failure")));
    var replacement = new FakeUsageSession();
    var sessions = new Queue<FakeUsageSession>([failing, replacement]);
    var publications = new ConcurrentQueue<(bool Present, UsageSnapshot Snapshot)>();
    var coordinator = CreateCoordinator(sessions, publications);

    coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    coordinator.PresenceChangedAsync(false, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    Assert(publications.TryPeek(out _), "cleanup failure produced no final publication");
    var absent = publications.Last();
    Assert(!absent.Present && absent.Snapshot == UsageSnapshot.Unavailable,
        "cleanup failure prevented final absent/unavailable state");

    coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    Assert(replacement.StartCount == 1, "ordinary cleanup error poisoned later sessions");
    coordinator.PresenceChangedAsync(false, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
}

static void UnconfirmedCleanupBlocksRestart()
{
    var unconfirmed = new FakeUsageSession(() => Task.FromException(
        new SessionCleanupUnconfirmedException("injected unconfirmed exit")));
    var unexpected = new FakeUsageSession();
    var sessions = new Queue<FakeUsageSession>([unconfirmed, unexpected]);
    var publications = new ConcurrentQueue<(bool Present, UsageSnapshot Snapshot)>();
    var coordinator = CreateCoordinator(sessions, publications);

    coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    coordinator.PresenceChangedAsync(false, CancellationToken.None).AsTask().GetAwaiter().GetResult();
    coordinator.PresenceChangedAsync(true, CancellationToken.None).AsTask().GetAwaiter().GetResult();

    Assert(unexpected.StartCount == 0, "restart created a second session after unconfirmed cleanup");
    Assert(sessions.Count == 1, "session factory was invoked after cleanup became unconfirmed");
    coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
}

static UsageSessionCoordinator CreateCoordinator(
    Queue<FakeUsageSession> sessions,
    ConcurrentQueue<(bool Present, UsageSnapshot Snapshot)> publications) =>
    new(
        _ => Task.FromResult<CodexExecutableCandidate?>(new CodexExecutableCandidate("test-helper", "test")),
        _ => sessions.Dequeue(),
        new BoundedDiagnosticLog(),
        (present, snapshot) => publications.Enqueue((present, snapshot)),
        (_, cancellationToken) => Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken));

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

static Rect BoundsIn(FrameworkElement element, Visual ancestor)
{
    var origin = element.TransformToAncestor(ancestor).Transform(new System.Windows.Point(0, 0));
    return new Rect(origin, new System.Windows.Size(element.ActualWidth, element.ActualHeight));
}

static IEnumerable<T> Descendants<T>(DependencyObject node) where T : DependencyObject
{
    for (var index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++)
    {
        var child = VisualTreeHelper.GetChild(node, index);
        if (child is T match) yield return match;
        foreach (var descendant in Descendants<T>(child)) yield return descendant;
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
    double dpi = 96,
    bool backdropAvailable = true)
{
    var surface = new OverlaySurface(
        animateColorFlow: false,
        culture: CultureInfo.GetCultureInfo("zh-CN"),
        timeZone: TimeZoneInfo.Utc)
    {
        Width = width,
        Height = height,
    };
    surface.SetBackdropAvailable(backdropAvailable);
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
    if (!backdropAvailable)
    {
        var antialiasedEdgePixels = 0;
        for (var offset = 3; offset < pixels.Length; offset += 4)
        {
            if (pixels[offset] is > 0 and < 255) antialiasedEdgePixels++;
        }
        Assert(antialiasedEdgePixels > 0, $"{fileName} has no partial-alpha edge pixels");
    }
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

static int CountProcessesByName(string processName)
{
    var processes = Process.GetProcessesByName(processName);
    try
    {
        return processes.Length;
    }
    finally
    {
        foreach (var process in processes) process.Dispose();
    }
}

static void ReleaseScriptDeclaresRestoreContract()
{
    var repo = Directory.GetCurrentDirectory();
    var scriptPath = Path.Combine(repo, "windows", "scripts", "package-release.ps1");
    var workflowPath = Path.Combine(repo, ".github", "workflows", "ci.yml");
    Assert(File.Exists(scriptPath) && File.Exists(workflowPath), "release contract files were not found");

    var script = File.ReadAllText(scriptPath);
    var workflow = File.ReadAllText(workflowPath);
    Assert(script.Contains("[switch]$NoRestore", StringComparison.Ordinal),
        "release script has no explicit NoRestore switch");
    Assert(script.Contains("dotnet restore", StringComparison.Ordinal),
        "release script cannot restore a clean checkout");
    Assert(script.Split("$LASTEXITCODE", StringSplitOptions.None).Length - 1 >= 2,
        "release script does not check restore and publish exit codes");
    Assert(workflow.Contains("package-release.ps1 -Version 0.1.0 -NoRestore", StringComparison.Ordinal),
        "CI does not explicitly reuse its completed restore");
}

static int RunFakeAppServer()
{
    if (int.TryParse(
            Environment.GetEnvironmentVariable("CODEX_QUOTA_TEST_CHILD_MAX_LIFETIME_MS"),
            out var maximumLifetimeMilliseconds))
    {
        _ = Task.Run(async () =>
        {
            await Task.Delay(maximumLifetimeMilliseconds).ConfigureAwait(false);
            Environment.Exit(0);
        });
    }

    var usedSequence = (Environment.GetEnvironmentVariable("CODEX_QUOTA_TEST_RATE_LIMIT_USED_SEQUENCE") ?? "7")
        .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Select(double.Parse)
        .ToArray();
    var rateLimitReads = 0;
    string? line;
    while ((line = Console.ReadLine()) is not null)
    {
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        if (!root.TryGetProperty("id", out var id) ||
            !root.TryGetProperty("method", out var methodElement))
        {
            continue;
        }

        var method = methodElement.GetString();
        object result;
        if (method == "account/rateLimits/read")
        {
            var usedPercent = usedSequence[Math.Min(rateLimitReads++, usedSequence.Length - 1)];
            result = new
            {
                rateLimits = new
                {
                    primary = new { usedPercent, windowDurationMins = 300, resetsAt = 1783987200 },
                    secondary = new { usedPercent, windowDurationMins = 10080, resetsAt = 1784505600 },
                },
            };
        }
        else
        {
            result = new { };
        }
        Console.WriteLine(JsonSerializer.Serialize(new { id = id.GetInt32(), result }));
        Console.Out.Flush();
    }
    return 0;
}

static string CreateTestRoot()
{
    var parent = Path.Combine(Path.GetTempPath(), "CodexQuota.Tests");
    Directory.CreateDirectory(parent);
    var root = Path.Combine(parent, Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    return root;
}

static void DeleteTestRoot(string root)
{
    var expectedParent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "CodexQuota.Tests"))
        .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
    var target = Path.GetFullPath(root);
    Assert(target.StartsWith(expectedParent, StringComparison.OrdinalIgnoreCase), "test cleanup escaped its temp root");
    if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
}

static void AssertThrows<TException>(Action action, string message) where TException : Exception
{
    try
    {
        action();
    }
    catch (TException)
    {
        return;
    }
    throw new InvalidOperationException(message);
}

static void Assert(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

file sealed class TrackingDisposable : IDisposable
{
    private int _disposeCount;
    public int DisposeCount => Volatile.Read(ref _disposeCount);
    public void Dispose() => Interlocked.Increment(ref _disposeCount);
}

file sealed class FakeUsageSession(Func<Task>? disposeAsync = null) : IUsageSession
{
    private readonly TaskCompletionSource _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Action<UsageSnapshot>? _snapshotChanged;
    private Action<UsageSnapshot>? _removedSnapshotHandlers;
    private int _startCount;
    private int _disposeCount;

    public event Action<UsageSnapshot>? SnapshotChanged
    {
        add => _snapshotChanged += value;
        remove
        {
            _snapshotChanged -= value;
            _removedSnapshotHandlers += value;
        }
    }

    public Task Completion => _completion.Task;
    public TaskCompletionSource DisposeStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public int StartCount => Volatile.Read(ref _startCount);
    public int DisposeCount => Volatile.Read(ref _disposeCount);

    public Task<UsageSnapshot> StartAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Interlocked.Increment(ref _startCount);
        return Task.FromResult(UsageSnapshot.Unavailable);
    }

    public async ValueTask DisposeAsync()
    {
        Interlocked.Increment(ref _disposeCount);
        DisposeStarted.TrySetResult();
        if (disposeAsync is not null)
        {
            await disposeAsync().ConfigureAwait(false);
        }
    }

    public void PublishCurrent(UsageSnapshot snapshot) => _snapshotChanged?.Invoke(snapshot);
    public void PublishAfterRemoval(UsageSnapshot snapshot) => _removedSnapshotHandlers?.Invoke(snapshot);
    public void Complete() => _completion.TrySetResult();
}
