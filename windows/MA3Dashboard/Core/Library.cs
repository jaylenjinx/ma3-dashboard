using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.RegularExpressions;
using System.Xml;

namespace MA3Dashboard.Core;

/// A grandMA3 user library folder (gma3_library), either the shared one or a per-version one.
public sealed record LibraryLocation(string Path, string Label)
{
    public string ThemesDir => System.IO.Path.Combine(Path, "colorthemes");
    public string FixturesDir => System.IO.Path.Combine(Path, "fixturetypes");
    public string DatapoolsDir => System.IO.Path.Combine(Path, "datapools");
    public override string ToString() => Label;

    public static List<LibraryLocation> All()
    {
        var root = Platform.MaRoot;
        var list = new List<LibraryLocation>();
        var shared = System.IO.Path.Combine(root, "gma3_library");
        if (Directory.Exists(shared)) list.Add(new(shared, "Shared library"));
        foreach (var d in Platform.SafeDirs(root).Select(System.IO.Path.GetFileName)
                     .Where(n => n!.StartsWith("gma3_") && n != "gma3_library")
                     .OrderByDescending(n => n, VersionComparer.Instance))
        {
            var lib = System.IO.Path.Combine(root, d!, "gma3_library");
            if (Directory.Exists(lib)) list.Add(new(lib, $"v{d![5..]} library"));
        }
        return list;
    }
}

static class Xml
{
    public static XmlReader Open(Stream s) => XmlReader.Create(s, new XmlReaderSettings
        { DtdProcessing = DtdProcessing.Ignore, IgnoreComments = true, IgnoreWhitespace = true, XmlResolver = null });

    public static Dictionary<string, string> Attributes(XmlReader r)
    {
        var d = new Dictionary<string, string>();
        if (r.MoveToFirstAttribute())
        {
            do d[r.Name] = r.Value; while (r.MoveToNextAttribute());
            r.MoveToElement();
        }
        return d;
    }
}

// MARK: - Color themes

public sealed record ThemeColor(string Name, string Rgba);
public sealed record ThemeGroup(string Name, List<ThemeColor> Colors);

public sealed record ColorTheme(string Path, string DataVersion, List<ThemeGroup> Groups, DateTime Modified)
{
    public string Name => System.IO.Path.GetFileNameWithoutExtension(Path).Replace("theme_", "");
    public int ColorCount => Groups.Sum(g => g.Colors.Count);
    public string FileName => System.IO.Path.GetFileName(Path);

    public string Color(string name, string group = "Global") =>
        (Groups.FirstOrDefault(g => g.Name == group) ?? Groups.FirstOrDefault())?.Colors.FirstOrDefault(c => c.Name == name)?.Rgba ?? "808080FF";
}

public static class ThemeScanner
{
    public static List<ColorTheme> Scan(string dir) =>
        Platform.SafeFiles(dir).Where(f => f.EndsWith(".xml", StringComparison.OrdinalIgnoreCase) && !Platform.IsHidden(f))
            .Select(Parse).OfType<ColorTheme>()
            .OrderBy(t => t.Name, StringComparer.CurrentCultureIgnoreCase).ToList();

    public static ColorTheme? Parse(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            using var r = Xml.Open(fs);
            var version = "";
            var groups = new List<ThemeGroup>();
            while (r.Read())
            {
                if (r.NodeType != XmlNodeType.Element) continue;
                switch (r.Name)
                {
                    case "GMA3": version = r.GetAttribute("DataVersion") ?? ""; break;
                    case "ColorDefGroup": groups.Add(new(r.GetAttribute("Name") ?? "?", [])); break;
                    case "ColorDef" when groups.Count > 0 && r.GetAttribute("Name") is { } n && r.GetAttribute("RGBA") is { } c:
                        groups[^1].Colors.Add(new(n, c)); break;
                }
            }
            return groups.Count == 0 ? null : new ColorTheme(path, version, groups, File.GetLastWriteTime(path));
        }
        catch { return null; }
    }
}

// MARK: - Fixture types

public enum FixtureFormat { Gdtf, Ma3, Ma2 }

public sealed record FixtureMode(string Name, int Channels);

public sealed record FixtureType(string Path, FixtureFormat Format, string Manufacturer, string Name, string Revision,
    List<FixtureMode> Modes, long Size, DateTime Modified)
{
    public string FileName => Uri.UnescapeDataString(System.IO.Path.GetFileName(Path));
    public string FormatText => Format switch { FixtureFormat.Gdtf => "GDTF", FixtureFormat.Ma3 => "MA3 XML", _ => "MA2 pxml" };
    public string ModesText => Modes.Count == 0 ? "—" : Modes.Count == 1 ? $"1 mode · {Modes[0].Channels} ch" : $"{Modes.Count} modes";
    public string SizeText => Platform.FormatBytes(Size);
    public string ModifiedText => Modified.ToString("g");
}

public static class FixtureScanner
{
    static readonly ConcurrentDictionary<string, (DateTime, FixtureType)> Cache = new();

    public static List<FixtureType> Scan(string dir) =>
        Platform.SafeFiles(dir).Select(path =>
            {
                FixtureFormat? format = System.IO.Path.GetExtension(path).ToLowerInvariant() switch
                {
                    ".gdtf" => FixtureFormat.Gdtf, ".xml" => FixtureFormat.Ma3, ".pxml" => FixtureFormat.Ma2, _ => null,
                };
                if (format == null || Platform.IsHidden(path)) return null;
                var info = new FileInfo(path);
                if (Cache.TryGetValue(path, out var hit) && hit.Item1 == info.LastWriteTimeUtc) return hit.Item2;
                var ft = Parse(path, format.Value, info.Length, info.LastWriteTime);
                Cache[path] = (info.LastWriteTimeUtc, ft);
                return ft;
            })
            .OfType<FixtureType>()
            .OrderBy(f => f.Manufacturer, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase).ToList();

    /// Reads the structure GDTF and MA3 share: FixtureType, DMXMode, DMXChannel, Revision.
    public static FixtureType Parse(string path, FixtureFormat format, long size, DateTime modified)
    {
        string name = "", manufacturer = "", revision = "";
        var modes = new List<FixtureMode>();
        try
        {
            Stream? s = null;
            ZipArchive? zip = null;
            if (format == FixtureFormat.Gdtf)
            {
                zip = ZipFile.OpenRead(path);
                s = zip.GetEntry("description.xml")?.Open();
            }
            else if (format == FixtureFormat.Ma3) s = File.OpenRead(path);
            // MA2 .pxml is a compressed library format; filename only.
            using (zip)
            using (s)
                if (s != null)
                {
                    using var r = Xml.Open(s);
                    string? mode = null;
                    var channels = 0;
                    while (r.Read())
                    {
                        if (r.NodeType == XmlNodeType.EndElement && r.Name == "DMXMode" && mode != null)
                        {
                            modes.Add(new(mode, channels)); mode = null; continue;
                        }
                        if (r.NodeType != XmlNodeType.Element) continue;
                        switch (r.Name)
                        {
                            case "FixtureType" when name == "":
                                name = r.GetAttribute("Name") ?? r.GetAttribute("LongName") ?? "";
                                manufacturer = r.GetAttribute("Manufacturer") ?? "";
                                break;
                            case "Revision":
                                revision = r.GetAttribute("Text") is { Length: > 0 } t ? t : r.GetAttribute("Date") ?? revision;
                                break;
                            case "DMXMode":
                                mode = r.GetAttribute("Name") ?? $"Mode {modes.Count + 1}";
                                channels = 0;
                                if (r.IsEmptyElement) { modes.Add(new(mode, 0)); mode = null; }
                                break;
                            case "DMXChannel" when mode != null:
                                channels++;
                                break;
                        }
                    }
                }
        }
        catch { }
        // Fall back to "Manufacturer@Name@Revision" filenames.
        var parts = Uri.UnescapeDataString(System.IO.Path.GetFileNameWithoutExtension(path)).Replace('_', ' ').Split('@');
        return new FixtureType(path, format,
            manufacturer != "" ? manufacturer : parts[0],
            name != "" ? name : parts.Length > 1 ? parts[1] : parts[0],
            revision == "" && parts.Length > 2 ? parts[2] : revision,
            modes, size, modified);
    }
}

// MARK: - Datapools (presets, plugins, macros, sequences, …)

public sealed record DatapoolItem(string Path, bool IsFolder, string Kind, string Name, string DataVersion,
    Dictionary<string, string> Attributes, List<string> Components, long Size, DateTime Modified)
{
    static readonly Regex Backup = new(@"\.bak(-|$)");
    public string FileName => System.IO.Path.GetFileName(Path);
    /// "Foo.lua.bak-1.2.0" style copies left behind by plugin development.
    public bool IsBackup => Backup.IsMatch(FileName);
    public string SizeText => Platform.FormatBytes(Size);
    public string Detail =>
        Attributes.TryGetValue("Version", out var v) ? $"v{v}" + (Attributes.TryGetValue("Author", out var a) ? $" · {a}" : "")
        : Attributes.TryGetValue("PresetMode", out var m) ? m : "";
}

public sealed record Datapool(string Name, string Path, List<DatapoolItem> Items)
{
    static readonly Dictionary<string, string> Special = new()
    {
        ["executorconfigurations"] = "Executor Configurations", ["executorpages"] = "Executor Pages",
        ["matricks"] = "MAtricks", ["quickeys"] = "Quickeys", ["timecodes"] = "Timecodes",
    };
    public string Title => Special.TryGetValue(Name, out var t) ? t : Name.Length == 0 ? Name : char.ToUpper(Name[0]) + Name[1..];
    public int VisibleCount => Items.Count(i => !i.IsBackup);
}

public static class DatapoolScanner
{
    public static List<Datapool> Scan(string dir) =>
        Platform.SafeDirs(dir).Where(d => !Platform.IsHidden(d))
            .Select(d => new Datapool(System.IO.Path.GetFileName(d), d, Items(d)))
            .OrderBy(p => p.Title, StringComparer.Ordinal).ToList();

    static List<DatapoolItem> Items(string pool)
    {
        IEnumerable<string> entries;
        try { entries = Directory.EnumerateFileSystemEntries(pool).ToList(); } catch { return []; }
        return entries.Where(e => !Platform.IsHidden(e) && System.IO.Path.GetFileName(e) != "libcache.dat").Select(path =>
        {
            var isFolder = Directory.Exists(path);
            var modified = isFolder ? Directory.GetLastWriteTime(path) : File.GetLastWriteTime(path);
            // A folder (e.g. a plugin with its own files) is described by the first .xml inside it.
            var xml = isFolder
                ? Platform.SafeFiles(path).FirstOrDefault(f => f.EndsWith(".xml", StringComparison.OrdinalIgnoreCase))
                : path.EndsWith(".xml", StringComparison.OrdinalIgnoreCase) ? path : null;
            var (kind, version, attrs, comps) = xml == null ? ("", "", new Dictionary<string, string>(), new List<string>()) : ParseItem(xml);
            var ext = System.IO.Path.GetExtension(path).TrimStart('.');
            var fallback = isFolder ? "Folder" : ext == "" ? "File" : ext.ToUpperInvariant();
            return new DatapoolItem(path, isFolder, kind == "" ? fallback : kind,
                attrs.TryGetValue("Name", out var n) ? n : System.IO.Path.GetFileNameWithoutExtension(path),
                version, attrs, comps, isFolder ? FolderSize(path) : new FileInfo(path).Length, modified);
        })
        .OrderBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// Reads just the first object under <GMA3> (and a plugin's ComponentLua children), then stops.
    static (string kind, string version, Dictionary<string, string> attrs, List<string> comps) ParseItem(string xml)
    {
        string kind = "", version = "";
        var attrs = new Dictionary<string, string>();
        var comps = new List<string>();
        try
        {
            using var fs = File.OpenRead(xml);
            using var r = Xml.Open(fs);
            var kindDepth = -1;
            while (r.Read())
            {
                if (r.NodeType == XmlNodeType.EndElement && r.Depth == kindDepth) break;
                if (r.NodeType != XmlNodeType.Element) continue;
                if (r.Name == "GMA3") { version = r.GetAttribute("DataVersion") ?? ""; continue; }
                if (kind == "")
                {
                    kind = r.Name; attrs = Xml.Attributes(r); kindDepth = r.Depth;
                    if (r.IsEmptyElement || kind != "Plugin") break;
                    continue;
                }
                if (r.Name == "ComponentLua" && r.GetAttribute("FileName") is { } f) comps.Add(f);
            }
        }
        catch { }
        return (kind, version, attrs, comps);
    }

    static long FolderSize(string dir)
    {
        try { return Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length); }
        catch { return 0; }
    }
}

// MARK: - File operations shared by the library managers

public static class LibraryFiles
{
    /// Copies files into a library folder without overwriting; returns how many were copied.
    public static int Import(IEnumerable<string> paths, string dir)
    {
        Directory.CreateDirectory(dir);
        var n = 0;
        foreach (var src in paths)
        {
            var dest = Platform.UniqueDestination(Path.Combine(dir, Path.GetFileName(src)));
            if (Directory.Exists(src)) CopyDirectory(src, dest); else File.Copy(src, dest);
            n++;
        }
        return n;
    }

    public static string Duplicate(string path, string suffix = "copy")
    {
        var (stem, ext) = Platform.SplitName(Path.GetFileName(path));
        var dest = Platform.UniqueDestination(Path.Combine(Path.GetDirectoryName(path)!, $"{stem}_{suffix}{ext}"));
        if (Directory.Exists(path)) CopyDirectory(path, dest); else File.Copy(path, dest);
        return dest;
    }

    static void CopyDirectory(string src, string dest)
    {
        Directory.CreateDirectory(dest);
        foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dest, Path.GetFileName(f)));
        foreach (var d in Directory.GetDirectories(src)) CopyDirectory(d, Path.Combine(dest, Path.GetFileName(d)));
    }
}
