using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace MA3Dashboard.Core;

/// Where grandMA software keeps its programs and data on this OS. Windows is the target; the macOS
/// paths match the Swift app so this build can be run and tested on a Mac.
public static class Platform
{
    public static readonly bool IsWindows = OperatingSystem.IsWindows();
    public static readonly bool IsMac = OperatingSystem.IsMacOS();

    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    static string ProgramData => Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);

    /// Our own settings/state folder: %AppData%\MA3Dashboard on Windows.
    public static string AppDataDir
    {
        get
        {
            var root = IsMac
                ? Path.Combine(Home, "Library", "Application Support")
                : Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            // A separate folder on the Mac so this build never shares sync state with the Swift app.
            var dir = Path.Combine(root, IsMac ? "MA3Dashboard-net" : "MA3Dashboard");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// grandMA3 data: C:\ProgramData\MALightingTechnology (gma3_x.y.z, gma3_library). Overridable in settings.
    public static string DefaultMaRoot => IsWindows
        ? Path.Combine(ProgramData, "MALightingTechnology")
        : Path.Combine(Home, "MALightingTechnology");

    public static string MaRoot => string.IsNullOrWhiteSpace(AppSettings.Current.Ma3DataRoot)
        ? DefaultMaRoot : AppSettings.Current.Ma3DataRoot!;

    public static string DownloadsDir => Path.Combine(Home, "Downloads");

    public static IEnumerable<string> ProgramFilesDirs()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in new[] {
                     Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                     Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                     Environment.GetEnvironmentVariable("ProgramW6432") })
            if (!string.IsNullOrEmpty(p) && Directory.Exists(p) && seen.Add(p)) yield return p;
    }

    /// Start Menu folders (all users + current user), where MA's installers put their shortcuts.
    public static IEnumerable<string> StartMenuDirs()
    {
        foreach (var f in new[] { Environment.SpecialFolder.CommonPrograms, Environment.SpecialFolder.Programs })
        {
            var p = Environment.GetFolderPath(f);
            if (!string.IsNullOrEmpty(p) && Directory.Exists(p)) yield return p;
        }
    }

    public static string CrossOverBottles => Path.Combine(Home, "Library", "Application Support", "CrossOver", "Bottles");
    public static string CrossOverApps => Path.Combine(Home, "Applications", "CrossOver");

    /// "MA Lighting Technologies\grandma" folders that hold gma2_V_x.y.z data folders.
    public static IEnumerable<string> Ma2DataRoots()
    {
        if (IsWindows)
        {
            yield return Path.Combine(ProgramData, "MA Lighting Technologies", "grandma");
            yield break;
        }
        if (!Directory.Exists(CrossOverBottles)) yield break;
        foreach (var bottle in SafeDirs(CrossOverBottles))
            yield return Path.Combine(bottle, "drive_c", "ProgramData", "MA Lighting Technologies", "grandma");
    }

    // MARK: File helpers

    public static string[] SafeDirs(string dir)
    {
        try { return Directory.GetDirectories(dir); } catch { return []; }
    }

    public static string[] SafeFiles(string dir)
    {
        try { return Directory.GetFiles(dir); } catch { return []; }
    }

    public static bool IsHidden(string path)
    {
        var name = Path.GetFileName(path);
        if (name.StartsWith('.')) return true;
        if (!IsWindows) return false;
        try { return (File.GetAttributes(path) & (FileAttributes.Hidden | FileAttributes.System)) != 0; }
        catch { return false; }
    }

    /// Recycle Bin on Windows, Trash on macOS.
    public static void Trash(string path)
    {
        if (IsWindows)
        {
            if (Directory.Exists(path))
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(path,
                    Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            else
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path,
                    Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            return;
        }
        var trash = Path.Combine(Home, ".Trash");
        Directory.CreateDirectory(trash);
        var dest = UniqueDestination(Path.Combine(trash, Path.GetFileName(path)));
        if (Directory.Exists(path)) Directory.Move(path, dest); else File.Move(path, dest);
    }

    public static string TrashName => IsWindows ? "Recycle Bin" : "Trash";

    /// "x.xml" → "x 2.xml", "x 3.xml", … until free. Keeps ".show.gz" together.
    public static string UniqueDestination(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path)!;
        var (stem, ext) = SplitName(Path.GetFileName(path));
        for (var i = 2; ; i++)
        {
            var c = Path.Combine(dir, $"{stem} {i}{ext}");
            if (!File.Exists(c) && !Directory.Exists(c)) return c;
        }
    }

    public static (string stem, string ext) SplitName(string name)
    {
        if (name.EndsWith(".show.gz", StringComparison.OrdinalIgnoreCase))
            return (name[..^8], name[^8..]);
        var ext = Path.GetExtension(name);
        return (name[..^ext.Length], ext);
    }

    /// Opens a folder in Explorer/Finder, or a file with its default app.
    public static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });

    public static void Reveal(string path)
    {
        if (IsWindows) Process.Start("explorer.exe", $"/select,\"{path}\"");
        else if (IsMac) Process.Start("open", ["-R", path]);
        else Open(Path.GetDirectoryName(path)!);
    }

    public static string Shell(string file, params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(file) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            return output;
        }
        catch { return ""; }
    }

    public static string FormatBytes(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double v = bytes;
        var i = 0;
        while (v >= 1000 && i < units.Length - 1) { v /= 1000; i++; }
        return i == 0 ? $"{bytes} bytes" : $"{v:0.#} {units[i]}";
    }

    public static string Architecture => RuntimeInformation.OSArchitecture.ToString();
}
