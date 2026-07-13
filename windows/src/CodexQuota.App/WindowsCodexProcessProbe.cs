using System.Diagnostics;
using CodexQuota.Core;

namespace CodexQuota.App;

internal sealed class WindowsCodexProcessProbe : ICodexProcessProbe
{
    private readonly BoundedDiagnosticLog _diagnostics;
    private readonly Func<CancellationToken, Process[]> _findOfficial;

    internal WindowsCodexProcessProbe(
        BoundedDiagnosticLog diagnostics,
        Func<CancellationToken, Process[]>? findOfficial = null)
    {
        _diagnostics = diagnostics;
        _findOfficial = findOfficial ?? WindowsCodexPackageProcesses.FindOfficial;
    }

    public ValueTask<IObservedCodexProcess?> FindRunningAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var processes = _findOfficial(cancellationToken);
        Process? selectedProcess = null;
        try
        {
            foreach (var process in processes)
            {
                cancellationToken.ThrowIfCancellationRequested();
                _diagnostics.Write("presence", "Official OpenAI desktop package process detected");
                selectedProcess = process;
                return ValueTask.FromResult<IObservedCodexProcess?>(new ObservedCodexProcess(process));
            }
        }
        finally
        {
            foreach (var process in processes)
            {
                if (!ReferenceEquals(process, selectedProcess))
                {
                    process.Dispose();
                }
            }
        }

        return ValueTask.FromResult<IObservedCodexProcess?>(null);
    }

    private sealed class ObservedCodexProcess(Process process) : IObservedCodexProcess
    {
        public int ProcessId => process.Id;

        public Task WaitForExitAsync(CancellationToken cancellationToken) =>
            process.WaitForExitAsync(cancellationToken);

        public void Dispose() => process.Dispose();
    }
}
