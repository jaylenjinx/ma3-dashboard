using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MA3Dashboard.Core;

namespace MA3Dashboard.ViewModels;

public partial class SyncViewModel : ObservableObject
{
    readonly MainViewModel main;
    SyncSettings S => main.Settings.Sync;
    public ObservableCollection<SyncLogEntry> Log { get; } = [];
    [ObservableProperty] private bool _syncing;
    [ObservableProperty] private string? _error;
    [ObservableProperty] private string? _summary;
    [ObservableProperty] private DateTimeOffset? _lastSync;
    [ObservableProperty] private string _token = TokenStore.Get();
    [ObservableProperty] private bool _testing;
    [ObservableProperty] private string? _testResult;
    [ObservableProperty] private bool _testOk;
    DispatcherTimer? autoTimer;

    public SyncViewModel(MainViewModel main)
    {
        this.main = main;
        _lastSync = main.Settings.LastSync;
    }

    public int[] Intervals { get; } = [0, 5, 15, 30, 60];

    public string ServerUrl { get => S.ServerUrl; set { S.ServerUrl = value; Save(); OnPropertyChanged(nameof(Configured)); OnPropertyChanged(nameof(Headline)); } }
    public string DeviceName { get => S.DeviceName; set { S.DeviceName = value; Save(); } }
    public bool Ma3Shows { get => S.Ma3Shows; set { S.Ma3Shows = value; Save(); } }
    public bool Ma3Library { get => S.Ma3Library; set { S.Ma3Library = value; Save(); } }
    public bool Ma2Shows { get => S.Ma2Shows; set { S.Ma2Shows = value; Save(); } }
    public int AutoSyncIndex
    {
        get => Math.Max(0, Array.IndexOf(Intervals, S.AutoSyncMinutes));
        set { S.AutoSyncMinutes = Intervals[Math.Clamp(value, 0, Intervals.Length - 1)]; Save(); Schedule(); }
    }

    /// The grandMA3 data folder; blank means the default (C:\ProgramData\MALightingTechnology).
    public string DataRoot
    {
        get => main.Settings.Ma3DataRoot ?? "";
        set
        {
            main.Settings.Ma3DataRoot = string.IsNullOrWhiteSpace(value) ? null : value.Trim();
            main.Settings.Save();
            OnPropertyChanged();
            main.Refresh();
            main.Library.Refresh();
        }
    }
    public string DataRootPlaceholder => Platform.DefaultMaRoot;

    public bool Configured => !string.IsNullOrWhiteSpace(S.ServerUrl) && !string.IsNullOrEmpty(Token);
    public string ServerSubtitle => string.IsNullOrWhiteSpace(S.ServerUrl) ? "Not configured" : S.ServerUrl;
    public string Headline => Syncing ? "Syncing…" : Error != null ? "Sync failed"
        : LastSync is { } d ? $"Last synced {Relative(d)}" : Configured ? "Not synced yet" : "Set up your sync server below";
    public string? Detail => Syncing ? null : Error ?? (LastSync != null ? Summary : null);
    public bool CanSync => !Syncing && Configured;
    public bool CanTest => !Testing && Configured;

    void Save()
    {
        main.Settings.Save();
        OnPropertyChanged(nameof(ServerSubtitle));
    }

    partial void OnTokenChanged(string value)
    {
        TokenStore.Set(value);
        OnPropertyChanged(nameof(Configured)); OnPropertyChanged(nameof(CanSync)); OnPropertyChanged(nameof(CanTest)); OnPropertyChanged(nameof(Headline));
    }
    partial void OnSyncingChanged(bool value) => Notify();
    partial void OnErrorChanged(string? value) => Notify();
    partial void OnTestingChanged(bool value) => OnPropertyChanged(nameof(CanTest));

    void Notify()
    {
        OnPropertyChanged(nameof(Headline)); OnPropertyChanged(nameof(Detail)); OnPropertyChanged(nameof(CanSync));
        main.UpdateSyncRow();
    }

    static string Relative(DateTimeOffset d)
    {
        var s = DateTimeOffset.Now - d;
        if (s.TotalSeconds < 60) return "just now";
        if (s.TotalMinutes < 60) return $"{(int)s.TotalMinutes} min ago";
        if (s.TotalHours < 24) return $"{(int)s.TotalHours} h ago";
        return d.LocalDateTime.ToString("g");
    }

    public void Start()
    {
        Schedule();
        // Keeps "Last synced n min ago" fresh.
        DispatcherTimer.Run(() => { OnPropertyChanged(nameof(Headline)); return true; }, TimeSpan.FromSeconds(30));
        if (S.AutoSyncMinutes > 0) SyncNow();
    }

    void Schedule()
    {
        autoTimer?.Stop();
        if (S.AutoSyncMinutes <= 0) return;
        autoTimer = new DispatcherTimer(TimeSpan.FromMinutes(S.AutoSyncMinutes), DispatcherPriority.Background, (_, _) => SyncNow());
        autoTimer.Start();
    }

    [RelayCommand]
    void SyncNow()
    {
        if (Syncing) return;
        SyncClient client;
        try { client = new SyncClient(S.ServerUrl, Token, S.DeviceName); }
        catch (Exception e) { Error = e.Message; return; }
        Syncing = true;
        Error = null;
        var roots = SyncRoot.Defaults(S);
        var engine = new SyncEngine(client, roots, e => Dispatcher.UIThread.Post(() =>
        {
            Log.Insert(0, e);
            while (Log.Count > 300) Log.RemoveAt(Log.Count - 1);
        }));
        Task.Run(engine.Run).ContinueWith(t => Dispatcher.UIThread.Post(() =>
        {
            Syncing = false;
            if (t.IsCompletedSuccessfully)
            {
                var s = t.Result;
                LastSync = DateTimeOffset.Now;
                main.Settings.LastSync = LastSync;
                main.Settings.Save();
                Summary = s + (s.Pending > 0 ? $" · {s.Pending} waiting for onPC to finish writing" : "");
                Notify();
                if (s.Downloaded + s.Deleted + s.Conflicts > 0) { main.Refresh(); main.Library.Refresh(); }
            }
            else Error = t.Exception?.InnerException?.Message ?? "Sync failed";
        }));
    }

    [RelayCommand]
    async Task Test()
    {
        Testing = true;
        try
        {
            await new SyncClient(S.ServerUrl, Token, S.DeviceName).Health();
            TestOk = true; TestResult = "Connected";
        }
        catch (Exception e) { TestOk = false; TestResult = e.Message; }
        Testing = false;
    }

    [RelayCommand]
    async Task BrowseDataRoot()
    {
        if (await main.Dialogs.PickFolder("Choose the grandMA3 data folder (contains gma3_library)") is { } dir) DataRoot = dir;
    }

    [RelayCommand] void ResetDataRoot() => DataRoot = "";

    [RelayCommand]
    void OpenServerHelp()
    {
        // The setup files ship next to the app's source; on a user machine point at the README online instead.
        var local = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "sync-server"));
        main.Try(() => Platform.Open(Directory.Exists(local) ? local : Platform.AppDataDir));
    }
}
