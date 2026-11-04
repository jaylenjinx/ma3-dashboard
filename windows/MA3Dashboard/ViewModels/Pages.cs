using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MA3Dashboard.Core;

namespace MA3Dashboard.ViewModels;

// MARK: - Versions and shows

public partial class VersionViewModel : ObservableObject, IDropTarget
{
    readonly MainViewModel main;
    [ObservableProperty] private MAVersion _version;
    [ObservableProperty] private ShowFile? _selectedShow;
    public ObservableCollection<ShowFile> Shows { get; } = [];

    public VersionViewModel(MainViewModel main, MAVersion v)
    {
        this.main = main;
        _version = v;
        foreach (var s in v.Shows) Shows.Add(s);
        main.VersionsChanged += () => { OnPropertyChanged(nameof(CanLoad)); OnPropertyChanged(nameof(LoadHint)); };
    }

    public void Update(MAVersion v)
    {
        Version = v;
        if (Shows.SequenceEqual(v.Shows)) return;
        var sel = SelectedShow?.Path;
        Shows.Clear();
        foreach (var s in v.Shows) Shows.Add(s);
        SelectedShow = Shows.FirstOrDefault(s => s.Path == sel);
    }

    partial void OnVersionChanged(MAVersion value)
    {
        foreach (var p in new[] { nameof(Title), nameof(Status), nameof(Builds), nameof(HasBuilds), nameof(HasManyBuilds), nameof(NewestBuild),
                     nameof(CanLoad), nameof(LoadHint), nameof(IsRunning), nameof(BackupText), nameof(StatusLine), nameof(IsMa3) })
            OnPropertyChanged(p);
    }

    public string Title => $"{Version.Product.Title()} {Version.Version}";
    public bool IsMa3 => Version.Product == Product.Ma3;
    public bool IsRunning => Version.IsRunning;
    public IReadOnlyList<MABuild> Builds => Version.Builds;
    public bool HasBuilds => Version.Builds.Count > 0;
    public bool HasManyBuilds => Version.Builds.Count > 1;
    public MABuild? NewestBuild => Version.NewestBuild;
    public string Status => Version.RunningBuild is { } b ? $"Running {b.Name} (pid {Version.Pid})"
        : Version.Builds.Count == 0 ? "Not installed on this computer" : "Not running";
    public string BackupText => Version.BackupCount == 0 ? "" : $"{Version.BackupCount} backup{(Version.BackupCount == 1 ? "" : "s")}";
    public string StatusLine => BackupText == "" ? Status : $"{Status} · {BackupText}";
    public bool CanLoad => IsMa3 && Version.IsRunning && main.OscListening;
    public string LoadHint => !IsMa3 ? "" : !Version.IsRunning ? "Launch this version to load shows from here"
        : !main.OscListening ? "Turn on OSC input (port 8000) in onPC to load shows from here" : "";

    [RelayCommand]
    void Launch(MABuild? build)
    {
        build ??= NewestBuild;
        if (build == null) return;
        // Covers the CleanStart twin too: both use this version's data folder, so only one can run.
        if (Version.RunningBuild is { } running) { main.Flash($"{running.Name} is already running"); return; }
        var other = main.Versions.FirstOrDefault(v => v.IsRunning);
        main.Try(() => Scanner.Launch(build), $"Launching {build.Name}" + (other != null ? $" ({other.RunningBuild!.Name} is also running)" : ""));
        main.Refresh();
    }

    [RelayCommand]
    async Task Load(ShowFile? show)
    {
        show ??= SelectedShow;
        if (show == null || !CanLoad) return;
        var name = show.Name.Replace("\"", "");
        try
        {
            await Osc.Send("/cmd", $"LoadShow \"{name}\"");
            main.Flash($"Sent LoadShow \"{name}\" to {Version.Version}. Confirm on the console if it asks.");
        }
        catch (Exception e) { main.Flash(e.Message, true); }
    }

    [RelayCommand]
    void Duplicate(ShowFile? show)
    {
        show ??= SelectedShow;
        if (show == null) return;
        var dest = Platform.UniqueDestination(Path.Combine(Path.GetDirectoryName(show.Path)!, $"{show.Name}_copy_{DateTime.Now:yyyyMMdd_HHmm}{show.Extension}"));
        main.Try(() => File.Copy(show.Path, dest), $"Copied to {Path.GetFileName(dest)}");
        main.Refresh();
    }

    [RelayCommand]
    void Reveal(ShowFile? show)
    {
        show ??= SelectedShow;
        if (show != null) main.Try(() => Platform.Reveal(show.Path));
    }

    [RelayCommand]
    async Task Trash(ShowFile? show)
    {
        show ??= SelectedShow;
        if (show == null || !await main.Dialogs.Confirm($"Move “{show.Name}” to the {Platform.TrashName}?",
                $"You can restore it from the {Platform.TrashName}.", $"Move to {Platform.TrashName}")) return;
        main.Try(() => Platform.Trash(show.Path), $"Moved {show.Name} to the {Platform.TrashName}");
        main.Refresh();
    }

    [RelayCommand]
    void OpenFolder()
    {
        Directory.CreateDirectory(Version.ShowsDir);
        main.Try(() => Platform.Open(Version.ShowsDir));
    }

    [RelayCommand]
    async Task ImportShows()
    {
        var files = await main.Dialogs.PickFiles("Import showfiles", IsMa3 ? ["show"] : ["gz", "show"]);
        Drop(files);
    }

    public void Drop(IReadOnlyList<string> paths)
    {
        var ok = paths.Where(p => p.EndsWith(".show", StringComparison.OrdinalIgnoreCase)
                                  || (!IsMa3 && p.EndsWith(".show.gz", StringComparison.OrdinalIgnoreCase))).ToList();
        if (paths.Count == 0) return;
        if (ok.Count == 0) { main.Flash(IsMa3 ? "Only .show files" : "Only .show.gz or .show files", true); return; }
        main.Try(() => LibraryFiles.Import(ok, Version.ShowsDir), $"Imported {ok.Count} show{(ok.Count == 1 ? "" : "s")}");
        main.Refresh();
    }
}

// MARK: - Library (shared by themes, fixture types and datapools)

public partial class LibraryViewModel : ObservableObject
{
    readonly MainViewModel main;
    public ObservableCollection<LibraryLocation> Locations { get; } = [];
    [ObservableProperty] private LibraryLocation? _selected;
    [ObservableProperty] private bool _loading;
    public List<ColorTheme> Themes { get; private set; } = [];
    public List<FixtureType> Fixtures { get; private set; } = [];
    public List<Datapool> Pools { get; private set; } = [];
    public event Action? Changed;
    bool updatingLocations;

    public LibraryViewModel(MainViewModel main) => this.main = main;

    partial void OnSelectedChanged(LibraryLocation? value)
    {
        if (updatingLocations || value == null) return;
        main.Settings.LibraryPath = value.Path;
        main.Settings.Save();
        Refresh();
    }

    public void Refresh()
    {
        var locs = LibraryLocation.All();
        if (!locs.SequenceEqual(Locations))
        {
            updatingLocations = true;
            Locations.Clear();
            foreach (var l in locs) Locations.Add(l);
            Selected = Locations.FirstOrDefault(l => l.Path == main.Settings.LibraryPath) ?? Locations.FirstOrDefault();
            updatingLocations = false;
        }
        var lib = Selected;
        if (lib == null) { Themes = []; Fixtures = []; Pools = []; Changed?.Invoke(); return; }
        Loading = true;
        Task.Run(() => (ThemeScanner.Scan(lib.ThemesDir), FixtureScanner.Scan(lib.FixturesDir), DatapoolScanner.Scan(lib.DatapoolsDir)))
            .ContinueWith(t => Dispatcher.UIThread.Post(() =>
            {
                Loading = false;
                if (!t.IsCompletedSuccessfully) return;
                (Themes, Fixtures, Pools) = t.Result;
                Changed?.Invoke();
            }));
    }

    public void Import(IReadOnlyList<string> paths, string[]? extensions, string dir)
    {
        if (paths.Count == 0) return;
        var ok = extensions == null ? paths.ToList()
            : paths.Where(p => extensions.Contains(Path.GetExtension(p).TrimStart('.').ToLowerInvariant())).ToList();
        if (ok.Count == 0) { main.Flash("Only " + string.Join(", ", extensions!.Select(e => "." + e)) + " files", true); return; }
        main.Try(() => LibraryFiles.Import(ok, dir), $"Imported {ok.Count} item{(ok.Count == 1 ? "" : "s")}");
        Refresh();
    }

    public void Duplicate(string path)
    {
        main.Try(() => main.Flash($"Created {Path.GetFileName(LibraryFiles.Duplicate(path))}"));
        Refresh();
    }

    public async Task Trash(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        var title = paths.Count == 1 ? $"Move “{Path.GetFileName(paths[0])}” to the {Platform.TrashName}?" : $"Move {paths.Count} items to the {Platform.TrashName}?";
        if (!await main.Dialogs.Confirm(title, $"You can restore it from the {Platform.TrashName}.", $"Move to {Platform.TrashName}")) return;
        main.Try(() => { foreach (var p in paths) Platform.Trash(p); }, $"Moved {paths.Count} to the {Platform.TrashName}");
        Refresh();
    }

    public void Reveal(string path) => main.Try(() => Platform.Reveal(path));

    public void OpenFolder(string dir)
    {
        main.Try(() => { Directory.CreateDirectory(dir); Platform.Open(dir); });
    }
}

public partial class ThemesViewModel : ObservableObject, IDropTarget
{
    readonly MainViewModel main;
    public LibraryViewModel Library => main.Library;
    public ObservableCollection<ColorTheme> Themes { get; } = [];
    [ObservableProperty] private ColorTheme? _selected;

    public ThemesViewModel(MainViewModel main)
    {
        this.main = main;
        main.Library.Changed += () =>
        {
            var sel = Selected?.Path;
            Themes.Clear();
            foreach (var t in main.Library.Themes) Themes.Add(t);
            Selected = Themes.FirstOrDefault(t => t.Path == sel) ?? Themes.FirstOrDefault();
            OnPropertyChanged(nameof(Subtitle));
        };
    }

    public string Subtitle => $"{Themes.Count} theme{(Themes.Count == 1 ? "" : "s")} in {Library.Selected?.Label ?? "no library"}";

    [RelayCommand]
    async Task Import() => Drop(await main.Dialogs.PickFiles("Import color themes", ["xml"]));

    public void Drop(IReadOnlyList<string> paths)
    {
        if (Library.Selected is { } lib) Library.Import(paths, ["xml"], lib.ThemesDir);
    }

    [RelayCommand] void Duplicate() { if (Selected != null) Library.Duplicate(Selected.Path); }
    [RelayCommand] void Reveal() { if (Selected != null) Library.Reveal(Selected.Path); }
    [RelayCommand] Task Trash() => Selected == null ? Task.CompletedTask : Library.Trash([Selected.Path]);
    [RelayCommand] void OpenFolder() { if (Library.Selected is { } lib) Library.OpenFolder(lib.ThemesDir); }
}

public partial class FixturesViewModel : ObservableObject, IDropTarget
{
    static readonly string[] Extensions = ["gdtf", "xml", "pxml"];
    readonly MainViewModel main;
    public LibraryViewModel Library => main.Library;
    public ObservableCollection<FixtureType> Filtered { get; } = [];
    public string[] Formats { get; } = ["All formats", "GDTF", "MA3 XML", "MA2 pxml"];
    [ObservableProperty] private FixtureType? _selected;
    [ObservableProperty] private string _search = "";
    [ObservableProperty] private string _format = "All formats";

    public FixturesViewModel(MainViewModel main)
    {
        this.main = main;
        main.Library.Changed += Apply;
    }

    partial void OnSearchChanged(string value) => Apply();
    partial void OnFormatChanged(string value) => Apply();

    void Apply()
    {
        var sel = Selected?.Path;
        var q = Search.Trim();
        Filtered.Clear();
        foreach (var f in Library.Fixtures.Where(f =>
                     (Format == Formats[0] || f.FormatText == Format) &&
                     (q == "" || f.Name.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                              || f.Manufacturer.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                              || f.FileName.Contains(q, StringComparison.CurrentCultureIgnoreCase))))
            Filtered.Add(f);
        Selected = Filtered.FirstOrDefault(f => f.Path == sel);
        OnPropertyChanged(nameof(Subtitle));
    }

    public string Subtitle
    {
        get
        {
            var all = Library.Fixtures;
            string Count(FixtureFormat f) => $"{all.Count(x => x.Format == f)}";
            return $"{all.Count} fixture types · {Count(FixtureFormat.Gdtf)} GDTF · {Count(FixtureFormat.Ma3)} MA3 · {Count(FixtureFormat.Ma2)} MA2";
        }
    }

    [RelayCommand]
    async Task Import() => Drop(await main.Dialogs.PickFiles("Import fixture types", Extensions));

    public void Drop(IReadOnlyList<string> paths)
    {
        if (Library.Selected is { } lib) Library.Import(paths, Extensions, lib.FixturesDir);
    }

    [RelayCommand] void Duplicate() { if (Selected != null) Library.Duplicate(Selected.Path); }
    [RelayCommand] void Reveal() { if (Selected != null) Library.Reveal(Selected.Path); }
    [RelayCommand] Task Trash() => Selected == null ? Task.CompletedTask : Library.Trash([Selected.Path]);
    [RelayCommand] void OpenFolder() { if (Library.Selected is { } lib) Library.OpenFolder(lib.FixturesDir); }
}

public partial class DatapoolsViewModel : ObservableObject, IDropTarget
{
    readonly MainViewModel main;
    public LibraryViewModel Library => main.Library;
    public ObservableCollection<Datapool> Pools { get; } = [];
    public ObservableCollection<DatapoolItem> Items { get; } = [];
    [ObservableProperty] private Datapool? _selectedPool;
    [ObservableProperty] private DatapoolItem? _selected;
    [ObservableProperty] private bool _showBackups;
    [ObservableProperty] private string? _preview;

    public DatapoolsViewModel(MainViewModel main)
    {
        this.main = main;
        main.Library.Changed += () =>
        {
            var name = SelectedPool?.Name;
            Pools.Clear();
            foreach (var p in main.Library.Pools) Pools.Add(p);
            SelectedPool = Pools.FirstOrDefault(p => p.Name == name) ?? Pools.FirstOrDefault(p => p.Items.Count > 0) ?? Pools.FirstOrDefault();
        };
    }

    partial void OnSelectedPoolChanged(Datapool? value) => ApplyItems();
    partial void OnShowBackupsChanged(bool value) => ApplyItems();

    void ApplyItems()
    {
        var sel = Selected?.Path;
        Items.Clear();
        foreach (var i in SelectedPool?.Items.Where(i => ShowBackups || !i.IsBackup) ?? []) Items.Add(i);
        Selected = Items.FirstOrDefault(i => i.Path == sel);
        OnPropertyChanged(nameof(BackupCount));
    }

    public int BackupCount => SelectedPool?.Items.Count(i => i.IsBackup) ?? 0;

    partial void OnSelectedChanged(DatapoolItem? value)
    {
        OnPropertyChanged(nameof(Attributes));
        Preview = null;
        if (value == null) return;
        // Show the Lua source for plugins (the first component, or the file itself).
        var lua = value.IsFolder
            ? value.Components.Select(c => Path.Combine(value.Path, c)).Concat(Platform.SafeFiles(value.Path).Where(f => f.EndsWith(".lua", StringComparison.OrdinalIgnoreCase))).FirstOrDefault(File.Exists)
            : value.Path.EndsWith(".lua", StringComparison.OrdinalIgnoreCase) ? value.Path : null;
        if (lua == null) return;
        try
        {
            using var r = new StreamReader(lua);
            var buf = new char[20000];
            var n = r.Read(buf, 0, buf.Length);
            Preview = new string(buf, 0, n) + (r.EndOfStream ? "" : "\n…");
        }
        catch { }
    }

    public IEnumerable<KeyValuePair<string, string>> Attributes =>
        Selected?.Attributes.Where(kv => kv.Key != "Name" && kv.Value != "").OrderBy(kv => kv.Key) ?? Enumerable.Empty<KeyValuePair<string, string>>();

    [RelayCommand]
    async Task Import() => Drop(await main.Dialogs.PickFiles($"Import into {SelectedPool?.Title}", []));

    public void Drop(IReadOnlyList<string> paths)
    {
        if (SelectedPool != null) Library.Import(paths, null, SelectedPool.Path);
    }

    [RelayCommand] void Duplicate() { if (Selected != null) Library.Duplicate(Selected.Path); }
    [RelayCommand] void Reveal() { if (Selected != null) Library.Reveal(Selected.Path); }
    [RelayCommand] Task Trash() => Selected == null ? Task.CompletedTask : Library.Trash([Selected.Path]);
    [RelayCommand] void OpenFolder() { if (SelectedPool != null) Library.OpenFolder(SelectedPool.Path); }
}

// MARK: - Installing

public partial class InstallerRow : ObservableObject
{
    public required InstallerPackage Package { get; init; }
    [ObservableProperty] private string _status = "";
    [ObservableProperty] private bool _isInstalled;
    [ObservableProperty] private bool _isNew;
    [ObservableProperty] private string? _progress;
    public bool IsIdle => Progress == null;
    partial void OnProgressChanged(string? value) => OnPropertyChanged(nameof(IsIdle));
    public string Title => $"{Package.Product.Title()} {Package.Version}";
    public string Detail => $"{Package.FileName} · {Package.SizeText} · {Package.Modified:d}";
}

public partial class InstallViewModel : ObservableObject, IDropTarget
{
    readonly MainViewModel main;
    public ObservableCollection<InstallerRow> Rows { get; } = [];
    public ObservableCollection<MABuild> Installed { get; } = [];

    public InstallViewModel(MainViewModel main) => this.main = main;

    // Short folder names in the subtitle (full paths wrapped onto three lines); the full paths are in the tooltip.
    public string SearchText => "Looking in " + string.Join(" and ", InstallerScanner.SearchDirs.Select(d =>
        string.Equals(d.TrimEnd('\\', '/'), Platform.DownloadsDir, StringComparison.OrdinalIgnoreCase) ? "Downloads" : Path.GetFileName(d.TrimEnd('\\', '/'))));
    public string SearchPaths => string.Join(Environment.NewLine, InstallerScanner.SearchDirs);
    public string Hint => Platform.IsWindows
        ? "Download onPC from malighting.com (grandMA3 \"onPC Windows\" zip, or the grandMA2 onPC .exe). The installer asks for administrator access."
        : "Download the grandMA3 onPC macOS zip from malighting.com.";
    public int NewCount => Rows.Count(r => r.IsNew);
    public bool IsEmpty => Rows.Count == 0;

    public void Update(List<InstallerPackage> pkgs)
    {
        if (pkgs.Select(p => p.Path).SequenceEqual(Rows.Select(r => r.Package.Path))) { UpdateInstalled(); return; }
        var busy = Rows.Where(r => r.Progress != null).ToDictionary(r => r.Package.Path);
        Rows.Clear();
        foreach (var p in pkgs) Rows.Add(busy.GetValueOrDefault(p.Path) ?? new InstallerRow { Package = p });
        OnPropertyChanged(nameof(IsEmpty));
        UpdateInstalled();
    }

    public void UpdateInstalled()
    {
        var builds = main.Versions.SelectMany(v => v.Builds).Where(b => !b.CleanStart).ToList();
        if (!builds.SequenceEqual(Installed)) { Installed.Clear(); foreach (var b in builds) Installed.Add(b); }
        foreach (var r in Rows)
        {
            var p = r.Package;
            var mine = builds.Where(b => b.Product == p.Product).ToList();
            r.IsInstalled = mine.Any(b => b.FullVersion == p.Version || (p.Version.Split('.').Length == 3 && b.DataVersion == p.Version));
            var newest = mine.Select(b => b.FullVersion).OrderByDescending(v => v, VersionComparer.Instance).FirstOrDefault();
            r.IsNew = !r.IsInstalled && (newest == null || VersionComparer.Instance.Compare(p.Version, newest) > 0);
            r.Status = r.IsInstalled ? "Installed" : r.IsNew ? "New" : "Older";
        }
        OnPropertyChanged(nameof(NewCount));
    }

    [RelayCommand]
    async Task Install(InstallerRow row)
    {
        if (row.Progress != null) return;
        row.Progress = "Preparing…";
        try
        {
            await Core.Installer.Install(row.Package, s => Dispatcher.UIThread.Post(() => row.Progress = s));
            main.Flash($"Installed {row.Title}");
        }
        catch (Exception e) { main.Flash(e.Message, true); }
        row.Progress = null;
        main.Refresh();
    }

    [RelayCommand]
    async Task OpenInstaller(InstallerRow row)
    {
        row.Progress = "Extracting…";
        try { await Core.Installer.Open(row.Package); }
        catch (Exception e) { main.Flash(e.Message, true); }
        row.Progress = null;
    }

    [RelayCommand] void Reveal(InstallerRow row) => main.Try(() => Platform.Reveal(row.Package.Path));
    [RelayCommand] void RevealBuild(MABuild b) => main.Try(() => Platform.Reveal(b.Path));

    [RelayCommand]
    async Task Add() => Drop(await main.Dialogs.PickFiles("Add installers", Platform.IsWindows ? ["zip", "exe"] : ["zip", "pkg"]));

    public void Drop(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        var ok = paths.Where(p => InstallerScanner.Classify(p) != null).ToList();
        if (ok.Count == 0) { main.Flash(Platform.IsWindows ? "Not an onPC Windows installer" : "Not a grandMA3 onPC mac installer (.zip or .pkg)", true); return; }
        main.Try(() => LibraryFiles.Import(ok, InstallerScanner.PackagesDir), $"Added {ok.Count} installer{(ok.Count == 1 ? "" : "s")}");
        main.Refresh();
    }
}
