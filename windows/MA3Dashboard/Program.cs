using Avalonia;
using System;
using System.Linq;

namespace MA3Dashboard;

class Program
{
    // Don't use any Avalonia, third-party APIs or any SynchronizationContext-reliant code before
    // AppMain is called: things aren't initialized yet and stuff might break.
    [STAThread]
    public static int Main(string[] args)
    {
        // The command-line modes are always redirected (a WinExe has no console of its own), so write UTF-8:
        // otherwise show names like "Café" and the ↑ ↓ log symbols come out as "?" in scan.txt.
        if (args.Contains("--scan") || args.Contains("--sync-once"))
            Console.SetOut(new System.IO.StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = true });
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
