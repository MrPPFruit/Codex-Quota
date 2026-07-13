using System.Diagnostics;
using CodexQuota.Core;

namespace CodexQuota.App;

internal sealed class WindowsCodexProcessProbe(BoundedDiagnosticLog diagnostics) : ICodexProcessProbe
{
    public ValueTask<IObservedCodexProcess?> FindRunningAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var processes = WindowsCodexPackageProcesses.FindOfficial(cancellationToken);
        Process? selectedProcess = null;
        try
        {
            foreach (var process in processes)
            {
                cancellationToken.ThrowIfCancellationRequested();
                selectedProcess = process;
                diagnostics.Write("presence", "Official OpenAI desktop package process detected");
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
