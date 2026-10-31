using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using MA3Dashboard.Core;
using Material.Icons;

namespace MA3Dashboard.ViewModels;

public partial class SidebarItem : ObservableObject
{
    public required string Key { get; init; }
    public bool IsHeader { get; init; }
    public bool IsSelectable => !IsHeader;
    [ObservableProperty] private string _title = "";
    [ObservableProperty] private string _subtitle = "";
    [ObservableProperty] private MaterialIconKind _icon;
    [ObservableProperty] private string? _badge;
    [ObservableProperty] private bool _isRunning;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private bool _hasWarning;
}

/// Pages that accept files dropped onto the window.
public interface IDropTarget
{
    void Drop(IReadOnlyList<string> paths);
}

/// What the views give the view models so they can show pickers and dialogs.
public interface IDialogs
{
    Task<IReadOnlyList<string>> PickFiles(string title, string[] extensions);
    Task<string?> PickFolder(string title);
    Task<bool> Confirm(string title, string message, string action);
}

public partial class MainViewModel : ObservableObject
{
    public ObservableCollection<SidebarItem> Sidebar { get; } = [];
    [ObservableProperty] private SidebarItem? _selectedItem;
    [ObservableProperty] private object? _currentPage;
    [ObservableProperty] private string? _message;
    [ObservableProperty] private bool _messageIsError;

    public IDialogs Dialogs { get; set; } = null!;
    public AppSettings Settings => AppSettings.Current;

    public List<MAVersion> Versions { get; private set; } = [];
    public bool OscListening { get; private set; }
    public event Action? VersionsChanged;

    public LibraryViewModel Library { get; }
    public ThemesViewModel Themes { get; }
    public FixturesViewModel Fixtures { get; }
    public DatapoolsViewModel Datapools { get; }
    public InstallViewModel Install { get; }
    public SyncViewModel Sync { get; }
    readonly Dictionary<string, VersionViewModel> versionPages = [];

    bool scanning, scanningInstallers, versionsLoaded;
    DateTime lastInstallerScan = DateTime.MinValue;
    readonly DispatcherTimer timer;

    public MainViewModel()
    {
        Library = new LibraryViewModel(this);
        Themes = new ThemesViewModel(this);
        Fixtures = new FixturesViewModel(this);
        Datapools = new DatapoolsViewModel(this);
        Install = new InstallViewModel(this);
        Sync = new SyncViewModel(this);
        RebuildSidebar();
        timer = new DispatcherTimer(TimeSpan.FromSeconds(3), DispatcherPriority.Background, (_, _) => Refresh());
    }

    public void Start()
    {
        Refresh();
        Library.Refresh();
        timer.Start();
        Sync.Start();
    }

    partial void OnSelectedItemChanged(SidebarItem? value)
    {
        if (value == null || value.IsHeader) return;
        Settings.Sidebar = value.Key;
        Settings.Save();
        CurrentPage = PageFor(value.Key);
        if (value.Key == "install") Refresh();
    }

    object? PageFor(string key) => key switch
    {
        "themes" => Themes,
        "fixtures" => Fixtures,
        "datapools" => Datapools,
        "install" => Install,
        "sync" => Sync,
        _ when key.StartsWith("v:") => VersionPage(key[2..]),
        _ => null,
    };

    VersionViewModel? VersionPage(string id)
    {
        var v = Versions.FirstOrDefault(x => x.Id == id);
        if (v == null) return null;
        if (!versionPages.TryGetValue(id, out var page)) versionPages[id] = page = new VersionViewModel(this, v);
        return page;
    }

    // MARK: Scanning

    public void Refresh()
    {
        // Installers live in Downloads, which can be slow (or a network folder), so they're scanned separately
        // and less often; versions never wait on them. Neither scan overlaps itself.
        if (!scanningInstallers && (SelectedItem?.Key == "install" || DateTime.Now - lastInstallerScan > TimeSpan.FromSeconds(60)))
        {
            scanningInstallers = true;
            Task.Run(InstallerScanner.Scan).ContinueWith(t => Dispatcher.UIThread.Post(() =>
            {
                scanningInstallers = false;
                lastInstallerScan = DateTime.Now;
                if (t.IsCompletedSuccessfully) Install.Update(t.Result);
                RebuildSidebar();
            }));
        }
        if (scanning) return;
        scanning = true;
        Task.Run(Scanner.Scan).ContinueWith(t => Dispatcher.UIThread.Post(() =>
        {
            scanning = false;
            if (!t.IsCompletedSuccessfully) return;
            var (versions, osc) = t.Result;
            versionsLoaded = true;
            var changed = versions.Count != Versions.Count || versions.Zip(Versions).Any(p => !p.First.SameAs(p.Second)) || osc != OscListening;
            Versions = versions;
            OscListening = osc;
            if (!changed && SelectedItem != null) return;
            foreach (var v in versions)
                if (versionPages.TryGetValue(v.Id, out var page)) page.Update(v);
            Install.UpdateInstalled();
            RebuildSidebar();
            VersionsChanged?.Invoke();
        }));
    }

    void RebuildSidebar()
    {
        var items = new List<SidebarItem>();
        void Header(string key, string title) => items.Add(new SidebarItem { Key = key, IsHeader = true, Title = title });
        void Version(MAVersion v) => items.Add(new SidebarItem
        {
            Key = "v:" + v.Id, Title = v.Version, Icon = v.Product == Product.Ma3 ? MaterialIconKind.Spotlight : MaterialIconKind.SpotlightBeam,
            Subtitle = $"{v.Shows.Count} show{(v.Shows.Count == 1 ? "" : "s")}" + (v.Builds.Count == 0 ? " · not installed" : ""),
            IsRunning = v.IsRunning,
        });

        var ma3 = Versions.Where(v => v.Product == Product.Ma3).ToList();
        var ma2 = Versions.Where(v => v.Product == Product.Ma2).ToList();
        if (ma3.Count > 0) { Header("h:ma3", "grandMA3 onPC"); ma3.ForEach(Version); }
        if (ma2.Count > 0) { Header("h:ma2", Platform.IsMac ? "grandMA2 onPC · CrossOver" : "grandMA2 onPC"); ma2.ForEach(Version); }
        Header("h:lib", "Library");
        items.Add(new SidebarItem { Key = "themes", Title = "Color Themes", Icon = MaterialIconKind.Palette });
        items.Add(new SidebarItem { Key = "fixtures", Title = "Fixture Types", Icon = MaterialIconKind.LightbulbGroup });
        items.Add(new SidebarItem { Key = "datapools", Title = "Datapools", Icon = MaterialIconKind.Database });
        Header("h:sw", "Software");
        var fresh = versionsLoaded ? Install.NewCount : 0;
        items.Add(new SidebarItem { Key = "install", Title = "Install Versions", Icon = MaterialIconKind.TrayArrowDown, Badge = fresh > 0 ? $"{fresh} new" : null });
        items.Add(new SidebarItem
        {
            Key = "sync", Title = "Cloud Sync", Icon = MaterialIconKind.Cloud,
            IsBusy = Sync.Syncing, HasWarning = Sync.Error != null,
        });

        // Update in place when the structure is unchanged, so the selection and scroll position stay put.
        if (items.Select(i => i.Key).SequenceEqual(Sidebar.Select(i => i.Key)))
        {
            foreach (var (n, o) in items.Zip(Sidebar))
            {
                o.Title = n.Title; o.Subtitle = n.Subtitle; o.Icon = n.Icon; o.Badge = n.Badge;
                o.IsRunning = n.IsRunning; o.IsBusy = n.IsBusy; o.HasWarning = n.HasWarning;
            }
        }
        else
        {
            var key = SelectedItem?.Key ?? Settings.Sidebar;
            Sidebar.Clear();
            foreach (var i in items) Sidebar.Add(i);
            SelectedItem = Sidebar.FirstOrDefault(i => i.Key == key && !i.IsHeader);
        }
        if (SelectedItem == null && Versions.Count > 0)
        {
            var v = Versions.FirstOrDefault(x => x.IsRunning) ?? Versions[0];
            SelectedItem = Sidebar.FirstOrDefault(i => i.Key == "v:" + v.Id);
        }
        else if (SelectedItem is { } sel && CurrentPage == null)
        {
            CurrentPage = PageFor(sel.Key);
        }
    }

    public void UpdateSyncRow() => RebuildSidebar();

    // MARK: Messages

    int flashId;

    public void Flash(string text, bool error = false)
    {
        Message = text;
        MessageIsError = error;
        var id = ++flashId;
        DispatcherTimer.RunOnce(() => { if (flashId == id) Message = null; }, TimeSpan.FromSeconds(error ? 8 : 4));
    }

    public void Try(Action action, string? success = null)
    {
        try
        {
            action();
            if (success != null) Flash(success);
        }
        catch (Exception e) { Flash(e.Message, true); }
    }
}
