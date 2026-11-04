using System;
using System.Linq;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.LogicalTree;
using Avalonia.Styling;

namespace MA3Dashboard.Views;

/// Windows draws the title bar itself, light by default, which left a white bar above the dark app.
/// This asks DWM for the dark title bar whenever the app is in its dark theme.
public static class WindowChrome
{
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    const int UseImmersiveDarkMode = 20;          // Windows 10 20H1 and later, Windows 11
    const int UseImmersiveDarkModeBefore20H1 = 19; // Windows 10 1809 to 1909

    /// Draws the app into the title bar area on Windows (sidebar to the top, Avalonia's own caption buttons), so there
    /// is no separate system title bar. MainWindow.axaml marks the drag areas and sizes them from WindowDecorationMargin.
    public const double TitleBarHeight = 40;

    public static void IntegrateTitleBar(Window window)
    {
        if (!OperatingSystem.IsWindows()) return;
        window.ExtendClientAreaToDecorationsHint = true;
        window.ExtendClientAreaTitleBarHeightHint = TitleBarHeight;
    }

    public static void FollowTheme(Window window)
    {
        if (!OperatingSystem.IsWindows()) return;
        window.Opened += (_, _) => Apply(window);
        window.ActualThemeVariantChanged += (_, _) => Apply(window);
    }

    static void Apply(Window window)
    {
        if (window.TryGetPlatformHandle()?.Handle is not { } hwnd || hwnd == IntPtr.Zero) return;
        var dark = window.ActualThemeVariant == ThemeVariant.Dark ? 1 : 0;
        if (DwmSetWindowAttribute(hwnd, UseImmersiveDarkMode, ref dark, sizeof(int)) != 0)
            DwmSetWindowAttribute(hwnd, UseImmersiveDarkModeBefore20H1, ref dark, sizeof(int));
    }
}

/// Screen readers (and UI Automation) named buttons after their content's type, like "Avalonia.Controls.StackPanel",
/// because most buttons hold an icon plus a label, or only an icon. This names each one after its label, or its
/// tooltip when it has no label, unless the XAML already set AutomationProperties.Name.
public static class AccessibleNames
{
    public static void Register()
    {
        Control.LoadedEvent.AddClassHandler<Button>((b, _) => Apply(b));
        Control.LoadedEvent.AddClassHandler<SplitButton>((b, _) => Apply(b));
    }

    static void Apply(ContentControl c)
    {
        if (c.IsSet(AutomationProperties.NameProperty) || c.Content is string) return;
        // The arrow half of a SplitButton (e.g. Launch → other builds, CleanStart).
        if (c.Name == "PART_SecondaryButton") { AutomationProperties.SetName(c, "More options"); return; }
        if (c.GetLogicalDescendants().OfType<TextBlock>().FirstOrDefault() is { } label)
            c.Bind(AutomationProperties.NameProperty, label.GetObservable(TextBlock.TextProperty));
        else if (ToolTip.GetTip(c) is string tip)
            AutomationProperties.SetName(c, tip);
    }
}
