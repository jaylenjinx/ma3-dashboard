using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Platform.Storage;
using MA3Dashboard.ViewModels;

namespace MA3Dashboard.Views;

public partial class MainWindow : Window, IDialogs
{
    public MainWindow()
    {
        InitializeComponent();
        WindowChrome.FollowTheme(this);
        WindowChrome.IntegrateTitleBar(this);
        AddHandler(DragDrop.DragOverEvent, (_, e) =>
            e.DragEffects = Vm?.CurrentPage is IDropTarget && e.DataTransfer.Contains(DataFormat.File) ? DragDropEffects.Copy : DragDropEffects.None);
        AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (Vm?.CurrentPage is not IDropTarget target) return;
            var paths = e.DataTransfer.TryGetFiles()?.Select(f => f.TryGetLocalPath()).OfType<string>().ToList() ?? [];
            target.Drop(paths);
        });
    }

    MainViewModel? Vm => DataContext as MainViewModel;

    protected override void OnDataContextChanged(System.EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (Vm != null) Vm.Dialogs = this;
    }

    public async Task<IReadOnlyList<string>> PickFiles(string title, string[] extensions)
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title, AllowMultiple = true,
            FileTypeFilter = extensions.Length == 0 ? null : [new FilePickerFileType(string.Join(", ", extensions.Select(x => "." + x))) { Patterns = extensions.Select(x => "*." + x).ToList() }],
        });
        return files.Select(f => f.TryGetLocalPath()).OfType<string>().ToList();
    }

    public async Task<string?> PickFolder(string title)
    {
        var dirs = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = title });
        return dirs.FirstOrDefault()?.TryGetLocalPath();
    }

    public async Task<bool> Confirm(string title, string message, string action)
    {
        var result = false;
        var dialog = new Window
        {
            Title = "MA3 Dashboard", SizeToContent = SizeToContent.WidthAndHeight, CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false, MinWidth = 380,
            Background = this.FindResource("PaneBrush") as Avalonia.Media.IBrush,
        };
        WindowChrome.FollowTheme(dialog);
        var ok = new Button { Content = action, Classes = { "accent" } };
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        ok.Click += (_, _) => { result = true; dialog.Close(); };
        cancel.Click += (_, _) => dialog.Close();
        dialog.Content = new StackPanel
        {
            Margin = new Thickness(24, 20), Spacing = 10, MaxWidth = 460,
            Children =
            {
                new TextBlock { Text = title, FontWeight = Avalonia.Media.FontWeight.SemiBold, FontSize = 15, TextWrapping = Avalonia.Media.TextWrapping.Wrap },
                new TextBlock { Text = message, TextWrapping = Avalonia.Media.TextWrapping.Wrap, Opacity = 0.75 },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0), Children = { cancel, ok } },
            },
        };
        await dialog.ShowDialog(this);
        return result;
    }
}
