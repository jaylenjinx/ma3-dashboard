using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace MA3Dashboard.Core;

// MARK: - What gets synced

/// A local folder mirrored to a remote prefix. Remote paths are platform-neutral ("ma3/2.5.1/shows/x.show")
/// and always use "/", so the Mac and Windows apps share one server.
public sealed class SyncRoot
{
    public string Prefix { get; set; } = "";
    public string Dir { get; set; } = "";
    public bool Recursive { get; set; }
    /// Lowercased filename suffixes to include; empty means everything.
    public List<string> Suffixes { get; set; } = [];
    /// Regexes matched against the relative path; matches are skipped.
    public List<string> Exclude { get; set; } = [];

    public bool Includes(string relative)
    {
        var lower = relative.ToLowerInvariant();
        if (Suffixes.Count > 0 && !Suffixes.Any(lower.EndsWith)) return false;
        return !Exclude.Any(x => Regex.IsMatch(relative, x));
    }

    public static List<SyncRoot> Defaults(SyncSettings s)
    {
        var roots = new List<SyncRoot>();
        var ma = Platform.MaRoot;
        if (s.Ma3Shows)
            foreach (var d in Platform.SafeDirs(ma).Select(Path.GetFileName).Order(StringComparer.Ordinal))
            {
                if (!Regex.IsMatch(d!, @"^gma3_\d+\.\d+\.\d+$")) continue;
                var shows = Path.Combine(ma, d!, "shared", "shows");
                if (Directory.Exists(shows)) roots.Add(new() { Prefix = $"ma3/{d![5..]}/shows", Dir = shows, Suffixes = [".show"] });
            }
        if (s.Ma3Library)
        {
            var lib = Path.Combine(ma, "gma3_library");
            roots.Add(new() { Prefix = "ma3/library/colorthemes", Dir = Path.Combine(lib, "colorthemes"), Suffixes = [".xml"] });
            roots.Add(new() { Prefix = "ma3/library/fixturetypes", Dir = Path.Combine(lib, "fixturetypes"), Suffixes = [".gdtf", ".xml", ".pxml"] });
            roots.Add(new() { Prefix = "ma3/library/datapools", Dir = Path.Combine(lib, "datapools"), Recursive = true,
                Exclude = [@"\.bak(-|$)", @"(^|/)libcache\.dat$"] });
        }
        if (s.Ma2Shows)
            foreach (var (v, dir) in Scanner.Ma2DataDirs())
                roots.Add(new() { Prefix = $"ma2/{v}/shows", Dir = Path.Combine(dir, "shows"), Suffixes = [".show.gz", ".show"] });
        return roots;
    }
}

// MARK: - Server API

public sealed class RemoteEntry
{
    public string? Sha { get; set; }
    public long Size { get; set; }
    /// Milliseconds since 1970.
    public double Mtime { get; set; }
    public int Rev { get; set; }
    public bool? Deleted { get; set; }
    public string? Device { get; set; }
}

public sealed class Manifest
{
    public int Rev { get; set; }
    public Dictionary<string, RemoteEntry> Files { get; set; } = [];
}

public sealed class SyncException(string message, int status = 0) : Exception(message)
{
    public int Status { get; } = status;
}

public sealed class SyncClient
{
    public const int ChunkSize = 16 * 1024 * 1024;
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(5) };

    public Uri Base { get; }
    public string Device { get; }
    readonly string token;

    public SyncClient(string server, string token, string device)
    {
        var s = server.Trim().TrimEnd('/');
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || u.Scheme is not ("http" or "https") || u.Host == "")
            throw new SyncException("Server URL must start with https:// (or http:// on your LAN)");
        if (string.IsNullOrEmpty(token)) throw new SyncException("Enter the server's SYNC_TOKEN");
        Base = new Uri(s + "/");
        this.token = token;
        Device = device;
    }

    HttpRequestMessage Request(HttpMethod method, string path, Dictionary<string, string>? query = null)
    {
        var url = path + (query is { Count: > 0 }
            ? "?" + string.Join('&', query.Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value)}"))
            : "");
        var r = new HttpRequestMessage(method, new Uri(Base, url));
        r.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return r;
    }

    async Task<HttpResponseMessage> Send(HttpRequestMessage r, HttpCompletionOption opt = HttpCompletionOption.ResponseContentRead)
    {
        var resp = await Http.SendAsync(r, opt);
        if (resp.IsSuccessStatusCode) return resp;
        var code = (int)resp.StatusCode;
        var body = await resp.Content.ReadAsStringAsync();
        string msg;
        try { msg = JsonDocument.Parse(body).RootElement.GetProperty("error").GetString() ?? body; }
        catch { msg = body.Length > 200 ? body[..200] : body; }
        resp.Dispose();
        throw new SyncException(code == 401 ? "Wrong sync token" : $"Server error {code}: {msg}", code);
    }

    public async Task Health()
    {
        using (var h = new HttpRequestMessage(HttpMethod.Get, new Uri(Base, "api/health")))
        using (await Send(h)) { }
        await GetManifest(); // also proves the token works
    }

    public async Task<Manifest> GetManifest()
    {
        using var resp = await Send(Request(HttpMethod.Get, "api/manifest"));
        return await resp.Content.ReadFromJsonAsync<Manifest>(Json) ?? new();
    }

    /// Uploads in chunks; `baseSha` is what we believe the server has (null = nothing), so a concurrent change returns 409.
    public async Task Upload(string file, string path, string sha, double mtimeMs, string? baseSha)
    {
        string id;
        using (var start = await Send(Request(HttpMethod.Post, "api/uploads")))
            id = JsonDocument.Parse(await start.Content.ReadAsStringAsync()).RootElement.GetProperty("id").GetString()
                 ?? throw new SyncException("Bad upload response");
        await using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            var buf = new byte[ChunkSize];
            long offset = 0;
            int n;
            while ((n = await ReadFull(fs, buf)) > 0)
            {
                var r = Request(HttpMethod.Put, $"api/uploads/{id}", new() { ["offset"] = offset.ToString() });
                r.Content = new ByteArrayContent(buf, 0, n);
                r.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
                using (await Send(r)) { }
                offset += n;
            }
        }
        var commit = Request(HttpMethod.Post, $"api/uploads/{id}/commit");
        commit.Content = JsonContent.Create(new Dictionary<string, object?>
            { ["path"] = path, ["sha"] = sha, ["mtime"] = mtimeMs, ["device"] = Device, ["baseSha"] = baseSha });
        using (await Send(commit)) { }
    }

    static async Task<int> ReadFull(Stream s, byte[] buf)
    {
        var total = 0;
        while (total < buf.Length)
        {
            var n = await s.ReadAsync(buf.AsMemory(total));
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    /// Downloads to a temp file and returns its path.
    public async Task<string> Download(string path)
    {
        var tmp = Path.Combine(Path.GetTempPath(), $"MA3Dashboard-dl-{Guid.NewGuid():N}");
        using var resp = await Send(Request(HttpMethod.Get, "api/file", new() { ["path"] = path }), HttpCompletionOption.ResponseHeadersRead);
        await using var src = await resp.Content.ReadAsStreamAsync();
        await using var dst = File.Create(tmp);
        await src.CopyToAsync(dst);
        return tmp;
    }

    public async Task Delete(string path, string? baseSha)
    {
        var q = new Dictionary<string, string> { ["path"] = path, ["device"] = Device };
        if (baseSha != null) q["baseSha"] = baseSha;
        using (await Send(Request(HttpMethod.Delete, "api/file", q))) { }
    }
}

// MARK: - Engine

public enum SyncKind { Upload, Download, Delete, Conflict, Error, Info }

public sealed record SyncLogEntry(SyncKind Kind, string Path, string Detail)
{
    public DateTime Date { get; } = DateTime.Now;
    public string Symbol => Kind switch
    {
        SyncKind.Upload => "↑", SyncKind.Download => "↓", SyncKind.Delete => "✕", SyncKind.Conflict => "⚠", SyncKind.Error => "!", _ => "·",
    };
    public string TimeText => Date.ToString("t");
}

public sealed class SyncSummary
{
    public int Uploaded, Downloaded, Deleted, Conflicts, Errors, Pending;

    public override string ToString()
    {
        var parts = new[] { (Uploaded, "up"), (Downloaded, "down"), (Deleted, "deleted"), (Conflicts, "conflicts"), (Errors, "errors") }
            .Where(p => p.Item1 > 0).Select(p => $"{p.Item1} {p.Item2}").ToList();
        return parts.Count == 0 ? "Everything up to date" : string.Join(" · ", parts);
    }
}

/// Three-way sync per file between the local folder, the server, and the state at the last sync. The same
/// algorithm as the Mac app: changes on one side propagate; changes on both sides keep both copies;
/// deletions go to the Recycle Bin locally and to versions/ on the server.
public sealed class SyncEngine
{
    public sealed class StateEntry
    {
        public string Sha { get; set; } = "";
        public long Size { get; set; }
        public double Mtime { get; set; }
    }

    public sealed class State
    {
        public Dictionary<string, StateEntry> Files { get; set; } = [];
    }

    sealed record LocalFile(string Path, long Size, double Mtime);

    readonly SyncClient client;
    readonly List<SyncRoot> roots;
    readonly Action<SyncLogEntry> log;
    public string StatePath { get; }
    /// Files modified more recently than this are probably still being written by onPC.
    public double SettleSeconds { get; set; } = 15;
    State state = new();

    public SyncEngine(SyncClient client, List<SyncRoot> roots, Action<SyncLogEntry> log, string? statePath = null)
    {
        this.client = client;
        this.roots = roots;
        this.log = log;
        StatePath = statePath ?? StatePathFor(client.Base);
    }

    /// One state file per server, so switching servers never mistakes "not on this server" for "deleted".
    public static string StatePathFor(Uri server)
    {
        var key = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(server.AbsoluteUri.TrimEnd('/').ToLowerInvariant())))[..16];
        return Path.Combine(Platform.AppDataDir, $"sync-state-{key}.json");
    }

    static double Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    static double Mtime(FileInfo f) => new DateTimeOffset(f.LastWriteTimeUtc).ToUnixTimeMilliseconds() / 1000.0;

    public async Task<SyncSummary> Run()
    {
        try { state = JsonSerializer.Deserialize<State>(await File.ReadAllTextAsync(StatePath), SyncClient.Json) ?? new(); }
        catch { state = new(); }
        var manifest = await client.GetManifest();
        var summary = new SyncSummary();

        foreach (var root in roots)
        {
            var local = Scan(root);
            var prefix = root.Prefix + "/";
            var remote = manifest.Files.Where(kv => kv.Key.StartsWith(prefix, StringComparison.Ordinal) && root.Includes(kv.Key[prefix.Length..]))
                .ToDictionary(kv => kv.Key, kv => kv.Value);
            var known = state.Files.Keys.Where(k => k.StartsWith(prefix, StringComparison.Ordinal));
            foreach (var path in local.Keys.Union(remote.Keys).Union(known).Order(StringComparer.Ordinal).ToList())
            {
                try
                {
                    await SyncOne(path, root, local.GetValueOrDefault(path), remote.GetValueOrDefault(path), summary);
                }
                catch (Exception e)
                {
                    summary.Errors++;
                    log(new(SyncKind.Error, path, e.Message));
                }
            }
        }
        SaveState();
        return summary;
    }

    Dictionary<string, LocalFile> Scan(SyncRoot root)
    {
        var output = new Dictionary<string, LocalFile>(StringComparer.Ordinal);
        if (!Directory.Exists(root.Dir)) return output;
        var baseDir = Path.GetFullPath(root.Dir).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var opts = new EnumerationOptions { RecurseSubdirectories = root.Recursive, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System };
        foreach (var f in Directory.EnumerateFiles(root.Dir, "*", opts))
        {
            var full = Path.GetFullPath(f);
            var rel = full[baseDir.Length..].Replace('\\', '/');
            // Hidden files and folders (".DS_Store", ".git") are skipped like the Mac app does.
            if (rel.Split('/').Any(p => p.StartsWith('.')) || !root.Includes(rel)) continue;
            var info = new FileInfo(full);
            output[$"{root.Prefix}/{rel}"] = new LocalFile(full, info.Length, Mtime(info));
        }
        return output;
    }

    static string LocalPath(string path, SyncRoot root) =>
        Path.Combine(root.Dir, path[(root.Prefix.Length + 1)..].Replace('/', Path.DirectorySeparatorChar));

    async Task SyncOne(string path, SyncRoot root, LocalFile? local, RemoteEntry? r, SyncSummary summary)
    {
        if (local != null && Now - local.Mtime < SettleSeconds) { summary.Pending++; return; }
        // Only an explicit deletion record on the server counts as "deleted remotely". A path the server has
        // never heard of (new or reset server) is treated as never synced, so local files get uploaded, not trashed.
        var baseEntry = r == null ? null : state.Files.GetValueOrDefault(path);
        string? lsha = local == null ? null
            : baseEntry != null && baseEntry.Size == local.Size && baseEntry.Mtime == local.Mtime ? baseEntry.Sha
            : await Sha256(local.Path);
        var rsha = r?.Deleted == true ? null : r?.Sha;

        if (lsha == rsha)
        {
            if (lsha != null && local != null) state.Files[path] = new() { Sha = lsha, Size = local.Size, Mtime = local.Mtime };
            else state.Files.Remove(path);
            return;
        }
        var localChanged = lsha != baseEntry?.Sha;
        var remoteChanged = rsha != baseEntry?.Sha;

        if ((localChanged && !remoteChanged) || (localChanged && remoteChanged && rsha == null))
        {
            if (local != null && lsha != null)
            {
                await Upload(local, lsha, path, rsha);
                summary.Uploaded++;
            }
            else
            {
                await client.Delete(path, rsha);
                state.Files.Remove(path);
                summary.Deleted++;
                log(new(SyncKind.Delete, path, "Deleted on server (kept in its history)"));
            }
        }
        else if ((!localChanged && remoteChanged) || (localChanged && remoteChanged && lsha == null))
        {
            if (r != null && rsha != null)
            {
                await Download(path, r, LocalPath(path, root));
                summary.Downloaded++;
            }
            else if (local != null)
            {
                Platform.Trash(local.Path);
                state.Files.Remove(path);
                summary.Deleted++;
                log(new(SyncKind.Delete, path, $"Deleted on another machine; moved to {Platform.TrashName}"));
            }
        }
        else if (localChanged && remoteChanged)
        {
            // Both sides changed: keep the local edit under a conflict name, take the server's copy as the original.
            if (local == null || lsha == null || r == null) return;
            var conflict = ConflictName(local.Path, client.Device);
            File.Move(local.Path, conflict);
            var baseDir = Path.GetFullPath(root.Dir).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var conflictPath = $"{root.Prefix}/{Path.GetFullPath(conflict)[baseDir.Length..].Replace('\\', '/')}";
            await Upload(local with { Path = conflict }, lsha, conflictPath, null);
            await Download(path, r, local.Path);
            summary.Conflicts++;
            log(new(SyncKind.Conflict, path, $"Changed on both sides; your copy kept as {Path.GetFileName(conflict)}"));
        }
        SaveState();
    }

    async Task Upload(LocalFile local, string sha, string path, string? baseSha)
    {
        try
        {
            await client.Upload(local.Path, path, sha, local.Mtime * 1000, baseSha);
        }
        catch (SyncException e) when (e.Status == 409)
        {
            throw new SyncException("Changed on the server during sync; will retry next sync");
        }
        state.Files[path] = new() { Sha = sha, Size = local.Size, Mtime = local.Mtime };
        log(new(SyncKind.Upload, path, Platform.FormatBytes(local.Size)));
    }

    async Task Download(string path, RemoteEntry r, string dest)
    {
        var tmp = await client.Download(path);
        try
        {
            var sha = await Sha256(tmp);
            if (sha != r.Sha) throw new SyncException($"Checksum mismatch downloading {path}");
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            File.SetLastWriteTimeUtc(tmp, DateTimeOffset.FromUnixTimeMilliseconds((long)r.Mtime).UtcDateTime);
            File.Move(tmp, dest, true);
            var info = new FileInfo(dest);
            state.Files[path] = new() { Sha = sha, Size = info.Length, Mtime = Mtime(info) };
            log(new(SyncKind.Download, path, Platform.FormatBytes(r.Size) + (string.IsNullOrEmpty(r.Device) ? "" : $" from {r.Device}")));
        }
        finally
        {
            if (File.Exists(tmp)) File.Delete(tmp);
        }
    }

    void SaveState()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
        var tmp = StatePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(state, SyncClient.Json));
        File.Move(tmp, StatePath, true);
    }

    public static async Task<string> Sha256(string path)
    {
        await using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1 << 20, true);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(fs));
    }

    public static string ConflictName(string path, string device)
    {
        var (stem, ext) = Platform.SplitName(Path.GetFileName(path));
        var safe = string.Concat(device.Select(c => Path.GetInvalidFileNameChars().Contains(c) || c is '/' or '\\' or ':' ? '-' : c));
        return Platform.UniqueDestination(Path.Combine(Path.GetDirectoryName(path)!,
            $"{stem} (conflict {safe} {DateTime.Now:yyyy-MM-dd HHmm}){ext}"));
    }
}

// MARK: - Headless mode for testing: MA3Dashboard --sync-once config.json

public static class HeadlessSync
{
    sealed class Config
    {
        public string Server { get; set; } = "";
        public string Token { get; set; } = "";
        public string Device { get; set; } = "";
        public string StatePath { get; set; } = "";
        public List<SyncRoot> Roots { get; set; } = [];
        public double? SettleSeconds { get; set; }
    }

    /// Returns an exit code when --sync-once was passed, otherwise null.
    public static int? RunIfRequested(string[] args)
    {
        var i = Array.IndexOf(args, "--sync-once");
        if (i < 0 || i + 1 >= args.Length) return null;
        try
        {
            var cfg = JsonSerializer.Deserialize<Config>(File.ReadAllText(args[i + 1]), SyncClient.Json)!;
            var engine = new SyncEngine(new SyncClient(cfg.Server, cfg.Token, cfg.Device), cfg.Roots,
                e => Console.WriteLine($"{e.Symbol} {e.Path}  {e.Detail}"), cfg.StatePath)
            { SettleSeconds = cfg.SettleSeconds ?? 15 };
            Console.WriteLine($"== {engine.Run().GetAwaiter().GetResult()}");
            return 0;
        }
        catch (Exception e)
        {
            Console.WriteLine($"FAILED: {e.Message}");
            return 1;
        }
    }
}

/// MA3Dashboard --scan: prints what the app detects, for checking paths on a new machine.
public static class ScanReport
{
    public static int? RunIfRequested(string[] args)
    {
        if (Array.IndexOf(args, "--scan") < 0) return null;
        var (versions, osc) = Scanner.Scan();
        Console.WriteLine($"MA3 data root: {Platform.MaRoot}   OSC listening: {osc}");
        foreach (var v in versions)
        {
            Console.WriteLine($"{v.Product.Title()} {v.Version}: {v.Shows.Count} shows, {v.BackupCount} backups, running: {v.RunningBuild?.Name ?? "no"}  [{v.ShowsDir}]");
            foreach (var b in v.Builds) Console.WriteLine($"    {b.Kind,-15} {b.Name}  {b.Path} {b.Arguments}");
        }
        foreach (var lib in LibraryLocation.All())
            Console.WriteLine($"{lib.Label}: {ThemeScanner.Scan(lib.ThemesDir).Count} themes, {FixtureScanner.Scan(lib.FixturesDir).Count} fixture types, "
                + string.Join(", ", DatapoolScanner.Scan(lib.DatapoolsDir).Select(p => $"{p.Title} {p.VisibleCount}")));
        foreach (var p in InstallerScanner.Scan()) Console.WriteLine($"Installer: {p.Product.Title()} {p.Version}  {p.Path}");
        foreach (var r in SyncRoot.Defaults(AppSettings.Current.Sync)) Console.WriteLine($"Sync root: {r.Prefix} <- {r.Dir}");
        return 0;
    }
}
