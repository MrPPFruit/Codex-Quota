namespace CodexQuota.Core;

public readonly record struct DesktopRect(double Left, double Top, double Width, double Height)
{
    public double Right => Left + Width;
    public double Bottom => Top + Height;
}

public readonly record struct OverlayFrame(double Left, double Top, double Width, double Height);

public static class OverlayPlacement
{
    public static OverlayFrame? ClampCentered(
        double centerX,
        double centerY,
        double width,
        double height,
        DesktopRect workArea)
    {
        if (!AllFinite(centerX, centerY, width, height, workArea.Left, workArea.Top, workArea.Width, workArea.Height) ||
            width <= 0 || height <= 0 || workArea.Width < width || workArea.Height < height)
        {
            return null;
        }

        return new OverlayFrame(
            Math.Clamp(centerX - width / 2, workArea.Left, workArea.Right - width),
            Math.Clamp(centerY - height / 2, workArea.Top, workArea.Bottom - height),
            width,
            height);
    }

    private static bool AllFinite(params double[] values) => values.All(double.IsFinite);
}
