using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MA3Dashboard.Core;

public sealed class SyncSettings
{
    public string ServerUrl { get; set; } = "";
    public bool Ma3Shows { get; set; } = true;
    public bool Ma3Library { get; set; } = true;
    public bool Ma2Shows { get; set; } = true;
    public int AutoSyncMinutes { get; set; }
    public string DeviceName { get; set; } = Environment.MachineName;
}

/// Everything the app remembers, in %AppData%\MA3Dashboard\settings.json.
public sealed class AppSettings
{
    public string? Ma3DataRoot { get; set; }
    public string? Sidebar { get; set; }
    public string? LibraryPath { get; set; }
    public DateTimeOffset? LastSync { get; set; }
    public SyncSettings Sync { get; set; } = new();

    static string FilePath => Path.Combine(Platform.AppDataDir, "settings.json");
    internal static readonly JsonSerializerOptions Json = new() { WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static AppSettings Current { get; } = Load();

    static AppSettings Load()
    {
        try { return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Json) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, Json));
        File.Move(tmp, FilePath, true);
    }
}

/// The sync token, encrypted with Windows DPAPI for the current user (a 0600 file elsewhere).
public static class TokenStore
{
    static string FilePath => Path.Combine(Platform.AppDataDir, "sync-token.bin");
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("MA3Dashboard Sync");

    public static string Get()
    {
        try
        {
            var data = File.ReadAllBytes(FilePath);
            if (OperatingSystem.IsWindows()) data = ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(data);
        }
        catch { return ""; }
    }

    public static void Set(string token)
    {
        if (string.IsNullOrEmpty(token)) { File.Delete(FilePath); return; }
        var data = Encoding.UTF8.GetBytes(token);
        if (OperatingSystem.IsWindows()) data = ProtectedData.Protect(data, Entropy, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(FilePath, data);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(FilePath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
}
