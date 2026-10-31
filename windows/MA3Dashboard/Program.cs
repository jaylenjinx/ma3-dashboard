using Avalonia;
using System;

namespace MA3Dashboard;

class Program
{
    // Don't use any Avalonia, third-party APIs or any SynchronizationContext-reliant code before
    // AppMain is called: things aren't initialized yet and stuff might break.
    [STAThread]
    public static int Main(string[] args)
    {
        if ((Core.HeadlessSync.RunIfRequested(args) ?? Core.ScanReport.RunIfRequested(args)) is { } code) return code;
        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
#if DEBUG
            .WithDeveloperTools()
#endif
            .WithInterFont()
            .LogToTrace();
}
