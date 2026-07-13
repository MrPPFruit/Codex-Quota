namespace CodexQuota.Core;

public static class DiagnosticRedactor
{
    public static string Sanitize(
        string message,
        string? userProfile = null,
        string? localApplicationData = null,
        string? temporaryDirectory = null)
    {
        var result = message;
        result = ReplaceRoot(result, userProfile, "%USERPROFILE%");
        result = ReplaceRoot(result, localApplicationData, "%LOCALAPPDATA%");
        result = ReplaceRoot(result, temporaryDirectory, "%TEMP%");
        return result.ReplaceLineEndings(" ");
    }

    private static string ReplaceRoot(string source, string? root, string replacement)
    {
        if (string.IsNullOrWhiteSpace(root))
        {
            return source;
        }

        return source.Replace(
            root.TrimEnd('\\', '/'),
            replacement,
            StringComparison.OrdinalIgnoreCase);
    }
}
