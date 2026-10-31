using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace MA3Dashboard.Core;

/// An onPC installer for this OS. Windows: MA's grandMA3 release zip (ma\*.exe + release xml), a bare
/// grandMA3 .exe, or a grandMA2 gMA2onPC_v*.exe. macOS: the grandMA3 zip (ma/*.pkg) or a .pkg.
public sealed record InstallerPackage(string Path, Product Product, string Version, long Size, DateTime Modified)
{
    public string DataVersion => string.Join('.', Version.Split('.').Take(3));
    public string FileName => System.IO.Path.GetFileName(Path);
    public string SizeText => Platform.FormatBytes(Size);
}

public static class InstallerScanner
{
    static readonly Regex VersionRx = new(@"v?(\d+\.\d+\.\d+(\.\d+)?)");
    public static string PackagesDir => Path.Combine(Platform.MaRoot, "installation_packages");
    public static string[] SearchDirs => [Platform.DownloadsDir, PackagesDir];

    public static string? Version(string path) =>
        VersionRx.Match(Path.GetFileName(path)) is { Success: true } m ? m.Groups[1].Value : null;

    public static Product? Classify(string path)
    {
        var n = Path.GetFileName(path).ToLowerInvariant();
        var ext = Path.GetExtension(n);
        if (Version(path) == null) return null;
        if (Platform.IsWindows)
        {
            if (n.StartsWith("gma2onpc") && ext == ".exe") return Product.Ma2;
            if (n.Contains("grandma3") && n.Contains("onpc") && n.Contains("win") && ext is ".zip" or ".exe") return Product.Ma3;
            return null;
        }
        // Skip Windows/Linux builds and console full packages.
        if (n.Contains("grandma3") && n.Contains("onpc") && ext is ".zip" or ".pkg" && !n.Contains("_win") && !n.Contains("linux"))
            return Product.Ma3;
        return null;
    }

    public static List<InstallerPackage> Scan()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return SearchDirs.SelectMany(Platform.SafeFiles)
            .Select(f => (f, product: Classify(f)))
            .Where(x => x.product != null && seen.Add(Path.GetFileName(x.f)))
            .Select(x => { var i = new FileInfo(x.f); return new InstallerPackage(x.f, x.product!.Value, Version(x.f)!, i.Length, i.LastWriteTime); })
            .OrderBy(p => p.Product).ThenByDescending(p => p.Version, VersionComparer.Instance).ToList();
    }
}

public static class Installer
{
    public sealed class Failure(string message) : Exception(message);

    /// Unzips an MA release zip into a scratch folder and returns the installer inside it.
    static (string installer, string? scratch) Extract(string path)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext != ".zip") return (path, null);
        var dest = Path.Combine(Path.GetTempPath(), $"MA3Dashboard-{Guid.NewGuid():N}");
        ZipFile.ExtractToDirectory(path, dest);
        var want = Platform.IsWindows ? "*.exe" : "*.pkg";
        var hit = Directory.EnumerateFiles(dest, want, SearchOption.AllDirectories).FirstOrDefault();
        if (hit != null) return (hit, dest);
        Directory.Delete(dest, true);
        throw new Failure($"No installer found in {Path.GetFileName(path)}");
    }

    /// Opens the extracted installer without waiting (for "Open Installer").
    public static async Task Open(InstallerPackage pkg)
    {
        var (installer, _) = await Task.Run(() => Extract(pkg.Path));
        Platform.Open(installer);
    }

    /// Runs MA's installer and waits for it. On Windows it asks for elevation itself (UAC); on macOS this
    /// runs Apple's `installer` behind the standard admin prompt.
    public static async Task Install(InstallerPackage pkg, Action<string> progress)
    {
        progress(pkg.Path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) ? "Extracting…" : "Preparing…");
        var (installer, scratch) = await Task.Run(() => Extract(pkg.Path));
        try
        {
            if (Platform.IsWindows)
            {
                progress("Installing… (follow the installer)");
                Process? p;
                try { p = Process.Start(new ProcessStartInfo(installer) { UseShellExecute = true, Verb = "runas" }); }
                catch (Win32Exception e) when (e.NativeErrorCode == 1223) { throw new Failure("Install cancelled"); }
                if (p == null) throw new Failure("Couldn't start the installer");
                await p.WaitForExitAsync();
                if (p.ExitCode != 0) throw new Failure(p.ExitCode == 2 ? "Install cancelled" : $"Installer exited with code {p.ExitCode}");
            }
            else
            {
                progress("Installing… (enter your password)");
                const string script = """
                    on run argv
                        do shell script "/usr/sbin/installer -pkg " & quoted form of (item 1 of argv) & " -target /" with administrator privileges
                    end run
                    """;
                var psi = new ProcessStartInfo("/usr/bin/osascript") { RedirectStandardError = true, RedirectStandardOutput = true };
                psi.ArgumentList.Add("-e"); psi.ArgumentList.Add(script); psi.ArgumentList.Add(installer);
                using var p = Process.Start(psi)!;
                var err = await p.StandardError.ReadToEndAsync();
                await p.WaitForExitAsync();
                if (p.ExitCode != 0)
                    throw new Failure(err.Contains("-128") || err.Contains("User canceled") ? "Install cancelled" : $"Install failed: {err.Trim()}");
            }
        }
        finally
        {
            if (scratch != null) try { Directory.Delete(scratch, true); } catch { }
        }
    }
}
