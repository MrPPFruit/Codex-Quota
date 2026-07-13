using CodexQuota.App;

var tests = new (string Name, Action Body)[]
{
    ("透明角不参与 hit-test", TransparentCornersPassThrough),
    ("圆泡中心参与 hit-test", BubbleCenterIsInteractive),
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
