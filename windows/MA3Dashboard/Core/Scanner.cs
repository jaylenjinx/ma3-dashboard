using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace MA3Dashboard.Core;

public enum Product { Ma3, Ma2 }

public static class ProductExt
{
    public static string Title(this Product p) => p == Product.Ma3 ? "grandMA3 onPC" : "grandMA2 onPC";
}

public sealed record ShowFile(string Path, long Size, DateTime Modified)
{
    /// grandMA3 shows are "x.show"; grandMA2 shows are "x.show.gz".
    public string Name => Platform.SplitName(System.IO.Path.GetFileName(Path)).stem;
    public string Extension => Platform.SplitName(System.IO.Path.GetFileName(Path)).ext;
    public string SizeText => Platform.FormatBytes(Size);
    public string ModifiedText => Modified.ToString("g");
}

public enum BuildKind
{
    /// An onPC executable, started directly (Windows).
    Exe,
    /// A Start Menu shortcut, when the executable itself couldn't be found (Windows).
    Shortcut,
    /// A standalone "grandMA3 onPC x.y.z.w.app" bundle (macOS).
    MacApp,
    /// A gma3_x.y.z slot inside the grandMA3.app launcher (macOS, 2.4 and older).
    MacLauncherSlot,
    /// A CrossOver wrapper app for grandMA2 (macOS).
    CrossOver,
}

/// One launchable onPC build.
public sealed record MABuild(Product Product, string FullVersion, BuildKind Kind, string Path)
{
    public string Arguments { get; init; } = "";
    public string? WorkingDir { get; init; }
    /// Folder the running process's executable lives in, used to tell which build is running.
    public string? InstallDir { get; init; }
    public string? Slot { get; init; }
    public bool CleanStart { get; init; }

    public string Id => $"{Product} {FullVersion}{(CleanStart ? " clean" : "")}";
    public string DataVersion => string.Join('.', FullVersion.Split('.').Take(3));
    public string Name => Kind switch
    {
        BuildKind.MacLauncherSlot => $"grandMA3 ({FullVersion})",
        BuildKind.Exe or BuildKind.Shortcut => $"{Product.Title()} {FullVersion}{(CleanStart ? " CleanStart" : "")}",
        _ => System.IO.Path.GetFileNameWithoutExtension(Path),
    };

    public bool Owns(RunningProcess p)
    {
        if (Product == Product.Ma2) return !CleanStart && p.IsMa2 && (InstallDir == null || p.Command.StartsWith(InstallDir, StringComparison.OrdinalIgnoreCase) || !Platform.IsWindows);
        if (p.IsMa2) return false;
        return Kind switch
        {
            BuildKind.MacApp => p.Command.StartsWith(Path + "/"),
            BuildKind.MacLauncherSlot => p.Command.StartsWith($"{Path}/Contents/MacOS/gma3_{Slot}/"),
            _ => InstallDir != null && p.Command.StartsWith(InstallDir, StringComparison.OrdinalIgnoreCase),
        };
    }
}

public sealed record RunningProcess(int Pid, string Command, bool IsMa2);

/// A gma3_x.y.z (or gma2_V_x.y.z) data folder plus the builds that use it.
public sealed record MAVersion(Product Product, string Version, IReadOnlyList<MABuild> Builds, string ShowsDir,
    IReadOnlyList<ShowFile> Shows, int BackupCount, MABuild? RunningBuild, int? Pid)
{
    public string Id => Product == Product.Ma3 ? Version : $"ma2:{Version}";
    public bool IsRunning => RunningBuild != null;
    public MABuild? NewestBuild => Builds.FirstOrDefault();

    public bool SameAs(MAVersion o) => Id == o.Id && Pid == o.Pid && BackupCount == o.BackupCount
        && Builds.SequenceEqual(o.Builds) && Shows.SequenceEqual(o.Shows);
}

public static class Scanner
{
    public const int OscPort = 8000;
    static readonly Regex Ma3Dir = new(@"^gma3_(\d+\.\d+\.\d+)$", RegexOptions.IgnoreCase);
    static readonly Regex VersionRx = new(@"\d+(\.\d+){2,3}");
    const string MacLauncher = "/Applications/grandMA3.app";

    public static (List<MAVersion> versions, bool oscListening) Scan()
    {
        var procs = RunningProcesses();
        return (ScanMa3(procs).Concat(ScanMa2(procs)).ToList(), OscListening());
    }

    static List<MAVersion> ScanMa3(List<RunningProcess> procs)
    {
        var builds = FindMa3Builds();
        var dirs = Platform.SafeDirs(Platform.MaRoot).Select(d => Ma3Dir.Match(System.IO.Path.GetFileName(d)))
            .Where(m => m.Success).Select(m => m.Groups[1].Value);
        return dirs.Union(builds.Select(b => b.DataVersion)).Select(v =>
        {
            var shared = System.IO.Path.Combine(Platform.MaRoot, $"gma3_{v}", "shared");
            var showsDir = System.IO.Path.Combine(shared, "shows");
            var mine = builds.Where(b => b.DataVersion == v).ToList();
            var (rb, pid) = FindRunning(mine, procs);
            return new MAVersion(Product.Ma3, v, mine, showsDir, ListShows(showsDir),
                ListShows(System.IO.Path.Combine(shared, "backups")).Count, rb, pid);
        })
        .OrderByDescending(v => v.Version, VersionComparer.Instance).ToList();
    }

    static (MABuild?, int?) FindRunning(List<MABuild> builds, List<RunningProcess> procs)
    {
        foreach (var p in procs)
            if (builds.FirstOrDefault(b => b.Owns(p)) is { } b) return (b, p.Pid);
        return (null, null);
    }

    // MARK: grandMA3 builds

    public static List<MABuild> FindMa3Builds()
    {
        var builds = Platform.IsWindows ? FindWindowsMa3Builds() : Platform.IsMac ? FindMacMa3Builds() : [];
        return builds.OrderByDescending(b => b.FullVersion, VersionComparer.Instance).ToList();
    }

    /// onPC installs as ...\MALightingTechnology\gma3_x.y.z\ under Program Files. We look for its executable
    /// there, and fall back to the Start Menu shortcuts MA's installer creates.
    static List<MABuild> FindWindowsMa3Builds()
    {
        var builds = new List<MABuild>();
        var roots = Platform.ProgramFilesDirs()
            .SelectMany(pf => new[] { "MALightingTechnology", "MA Lighting Technologies", @"MA Lighting Technologies\grandMA3" }
                .Select(s => System.IO.Path.Combine(pf, s)))
            .Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase);
        foreach (var root in roots)
        foreach (var dir in Platform.SafeDirs(root))
        {
            var m = Ma3Dir.Match(System.IO.Path.GetFileName(dir));
            if (!m.Success || FindExe(dir, ["app_gma3.exe", "gma3onpc.exe", "onpc.exe", "grandma3*.exe"], 3) is not { } exe) continue;
            var full = FileVersion(exe) is { } fv && fv.StartsWith(m.Groups[1].Value) ? fv : m.Groups[1].Value;
            builds.Add(new MABuild(Product.Ma3, full, BuildKind.Exe, exe)
                { WorkingDir = System.IO.Path.GetDirectoryName(exe), InstallDir = dir });
        }
        foreach (var lnk in StartMenuShortcuts("grandma3 onpc"))
        {
            var v = VersionRx.Match(System.IO.Path.GetFileNameWithoutExtension(lnk));
            if (!v.Success || builds.Any(b => b.DataVersion == string.Join('.', v.Value.Split('.').Take(3)))) continue;
            builds.Add(new MABuild(Product.Ma3, v.Value, BuildKind.Shortcut, lnk));
        }
        return builds;
    }

    static List<MABuild> FindMacMa3Builds()
    {
        var builds = new List<MABuild>();
        foreach (var app in Platform.SafeDirs("/Applications"))
        {
            var name = System.IO.Path.GetFileName(app);
            if (name.StartsWith("grandMA3 onPC") && name.EndsWith(".app") && PlistVersion(System.IO.Path.Combine(app, "Contents/Info.plist")) is { } v)
                builds.Add(new MABuild(Product.Ma3, v, BuildKind.MacApp, app));
        }
        foreach (var slotDir in Platform.SafeDirs($"{MacLauncher}/Contents/MacOS"))
        {
            var slot = System.IO.Path.GetFileName(slotDir);
            // Slots without app_gma3 (e.g. "2.5.1_application") just hand off to a standalone app.
            if (!slot.StartsWith("gma3_") || !File.Exists(System.IO.Path.Combine(slotDir, "app_gma3"))
                || PlistVersion(System.IO.Path.Combine(slotDir, "Info.plist")) is not { } v) continue;
            builds.Add(new MABuild(Product.Ma3, v, BuildKind.MacLauncherSlot, MacLauncher) { Slot = slot[5..] });
        }
        return builds;
    }

    // MARK: grandMA2

    public static List<(string version, string dir)> Ma2DataDirs() =>
        Platform.Ma2DataRoots().SelectMany(root => Platform.SafeDirs(root)
                .Where(d => System.IO.Path.GetFileName(d).StartsWith("gma2_V_", StringComparison.OrdinalIgnoreCase))
                .Select(d => (System.IO.Path.GetFileName(d)[7..], d)))
            .ToList();

    public static List<MABuild> FindMa2Builds()
    {
        var builds = new List<MABuild>();
        if (Platform.IsWindows)
        {
            // ...\MA Lighting Technologies\grandma\grandMA2 onPC 3.9.63.11\gma2onpc.exe; the CleanStart shortcut
            // runs the same exe with "CLEANSTART NOLOAD" from the gma2_V_ data folder.
            var dataRoot = Platform.Ma2DataRoots().First();
            foreach (var pf in Platform.ProgramFilesDirs())
            foreach (var dir in Platform.SafeDirs(System.IO.Path.Combine(pf, "MA Lighting Technologies", "grandma")))
            {
                var exe = System.IO.Path.Combine(dir, "gma2onpc.exe");
                var v = VersionRx.Match(System.IO.Path.GetFileName(dir));
                if (!File.Exists(exe) || !v.Success || builds.Any(b => b.Path.Equals(exe, StringComparison.OrdinalIgnoreCase))) continue;
                var data = System.IO.Path.Combine(dataRoot, "gma2_V_" + string.Join('.', v.Value.Split('.').Take(3)));
                builds.Add(new MABuild(Product.Ma2, v.Value, BuildKind.Exe, exe) { WorkingDir = data, InstallDir = dir });
                builds.Add(new MABuild(Product.Ma2, v.Value, BuildKind.Exe, exe)
                    { WorkingDir = data, InstallDir = dir, Arguments = "CLEANSTART NOLOAD", CleanStart = true });
            }
        }
        else if (Platform.IsMac && Directory.Exists(Platform.CrossOverApps))
        {
            foreach (var app in Directory.EnumerateDirectories(Platform.CrossOverApps, "grandMA2 onPC *.app", SearchOption.AllDirectories))
            {
                var name = System.IO.Path.GetFileNameWithoutExtension(app);
                var v = VersionRx.Match(name);
                if (v.Success) builds.Add(new MABuild(Product.Ma2, v.Value, BuildKind.CrossOver, app) { CleanStart = name.EndsWith("CleanStart") });
            }
        }
        return builds.OrderByDescending(b => b.FullVersion, VersionComparer.Instance).ThenBy(b => b.CleanStart).ToList();
    }

    static List<MAVersion> ScanMa2(List<RunningProcess> procs)
    {
        var builds = FindMa2Builds();
        var dirs = Ma2DataDirs();
        return dirs.Select(d => d.version).Union(builds.Select(b => b.DataVersion)).Select(v =>
        {
            var dir = dirs.FirstOrDefault(d => d.version == v).dir;
            var showsDir = dir == null ? "" : System.IO.Path.Combine(dir, "shows");
            var mine = builds.Where(b => b.DataVersion == v).ToList();
            var (rb, pid) = FindRunning(mine, procs);
            var backups = dir == null ? 0 : Platform.SafeFiles(showsDir).Count(f => f.EndsWith(".backup", StringComparison.OrdinalIgnoreCase));
            return new MAVersion(Product.Ma2, v, mine, showsDir, dir == null ? [] : ListShows(showsDir), backups, rb, pid);
        })
        .OrderByDescending(v => v.Version, VersionComparer.Instance).ToList();
    }

    // MARK: Helpers

    public static List<ShowFile> ListShows(string dir) =>
        Platform.SafeFiles(dir)
            .Where(f => !Platform.IsHidden(f) && (f.EndsWith(".show", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".show.gz", StringComparison.OrdinalIgnoreCase)))
            .Select(f => { var i = new FileInfo(f); return new ShowFile(f, i.Length, i.LastWriteTime); })
            .OrderByDescending(s => s.Modified).ToList();

    static string? FindExe(string dir, string[] patterns, int depth)
    {
        foreach (var pattern in patterns)
        {
            try
            {
                var hit = Directory.EnumerateFiles(dir, pattern, new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = depth, IgnoreInaccessible = true })
                    .FirstOrDefault(f => !System.IO.Path.GetFileName(f).Contains("uninst", StringComparison.OrdinalIgnoreCase));
                if (hit != null) return hit;
            }
            catch { }
        }
        return null;
    }

    static IEnumerable<string> StartMenuShortcuts(string prefix) =>
        Platform.StartMenuDirs().SelectMany(d =>
        {
            try { return Directory.EnumerateFiles(d, "*.lnk", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true }); }
            catch { return []; }
        })
        .Where(f =>
        {
            var n = System.IO.Path.GetFileName(f).ToLowerInvariant();
            return n.StartsWith(prefix) && !n.Contains("uninstall") && !n.Contains("show folder");
        });

    static string? FileVersion(string exe)
    {
        try
        {
            var vi = FileVersionInfo.GetVersionInfo(exe);
            var s = vi.ProductVersion ?? vi.FileVersion;
            return s != null && VersionRx.Match(s) is { Success: true } m ? m.Value : null;
        }
        catch { return null; }
    }

    static string? PlistVersion(string plist)
    {
        try
        {
            var text = File.ReadAllText(plist);
            foreach (var key in new[] { "CFBundleVersion", "CFBundleShortVersionString" })
            {
                var m = Regex.Match(text, $@"<key>{key}</key>\s*<string>([^<]+)</string>");
                if (m.Success) return m.Groups[1].Value.Trim();
            }
        }
        catch { }
        return null;
    }

    public static List<RunningProcess> RunningProcesses()
    {
        var list = new List<RunningProcess>();
        if (Platform.IsWindows)
        {
            foreach (var p in Process.GetProcesses())
            {
                var n = p.ProcessName.ToLowerInvariant();
                var ma2 = n == "gma2onpc";
                if (!ma2 && n is not ("app_gma3" or "gma3onpc" or "onpc")) { p.Dispose(); continue; }
                string path;
                try { path = p.MainModule?.FileName ?? n; } catch { path = n; }
                list.Add(new RunningProcess(p.Id, path, ma2));
                p.Dispose();
            }
            return list;
        }
        foreach (var line in Platform.Shell("/bin/ps", "-axo", "pid=,command=").Split('\n'))
        {
            var t = line.Trim();
            var ma2 = t.Contains("gma2onpc.exe", StringComparison.OrdinalIgnoreCase);
            if (!ma2 && !Regex.IsMatch(t, @"/app_gma3(\s|$)")) continue;
            var sp = t.IndexOf(' ');
            if (sp > 0 && int.TryParse(t[..sp], out var pid)) list.Add(new RunningProcess(pid, t[sp..].Trim(), ma2));
        }
        return list;
    }

    public static bool OscListening()
    {
        if (Platform.IsMac) return Platform.Shell("/usr/sbin/lsof", "-nP", $"-iUDP:{OscPort}").Contains("app_gma3");
        try { return IPGlobalProperties.GetIPGlobalProperties().GetActiveUdpListeners().Any(e => e.Port == OscPort); }
        catch { return false; }
    }

    public static void Launch(MABuild b)
    {
        switch (b.Kind)
        {
            case BuildKind.Exe:
                Process.Start(new ProcessStartInfo(b.Path)
                {
                    Arguments = b.Arguments, UseShellExecute = true,
                    WorkingDirectory = b.WorkingDir != null && Directory.Exists(b.WorkingDir) ? b.WorkingDir : System.IO.Path.GetDirectoryName(b.Path)!,
                });
                break;
            case BuildKind.Shortcut:
                Platform.Open(b.Path);
                break;
            case BuildKind.MacLauncherSlot:
                // The launcher starts whatever current_version names, same as MA's own version switch.
                File.WriteAllText($"{b.Path}/Contents/MacOS/current_version", b.Slot);
                Process.Start("open", [b.Path]);
                break;
            default:
                Process.Start("open", [b.Path]);
                break;
        }
    }
}

public static class Osc
{
    /// Sends a single-string OSC message to onPC on localhost.
    public static async Task Send(string address, string value)
    {
        static byte[] Pad(string s)
        {
            var b = Encoding.UTF8.GetBytes(s);
            var arr = new byte[(b.Length / 4 + 1) * 4];
            b.CopyTo(arr, 0);
            return arr;
        }
        var packet = Pad(address).Concat(Pad(",s")).Concat(Pad(value)).ToArray();
        using var udp = new UdpClient();
        await udp.SendAsync(packet, packet.Length, "127.0.0.1", Scanner.OscPort);
    }
}

/// Orders "2.10.0" after "2.9.1".
public sealed class VersionComparer : IComparer<string?>
{
    public static readonly VersionComparer Instance = new();

    public int Compare(string? a, string? b)
    {
        var x = (a ?? "").Split('.', '-', ' ');
        var y = (b ?? "").Split('.', '-', ' ');
        for (var i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            var p = i < x.Length ? x[i] : "";
            var q = i < y.Length ? y[i] : "";
            var c = int.TryParse(p, out var pi) && int.TryParse(q, out var qi) ? pi.CompareTo(qi) : string.Compare(p, q, StringComparison.OrdinalIgnoreCase);
            if (c != 0) return c;
        }
        return 0;
    }
}
