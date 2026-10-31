using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Avalonia.Data.Converters;
using Avalonia.Media;
using MA3Dashboard.Core;

namespace MA3Dashboard.Views;

/// "RRGGBBAA" (MA's RGBA hex) → brush.
public sealed class RgbaBrush : IValueConverter
{
    public static readonly RgbaBrush Instance = new();

    public static Color ToColor(string? s)
    {
        s ??= "";
        if (!uint.TryParse(s.Length >= 8 ? s[..8] : s, NumberStyles.HexNumber, null, out var v)) return Colors.Gray;
        return s.Length >= 8
            ? Color.FromArgb((byte)(v & 0xFF), (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8))
            : Color.FromRgb((byte)(v >> 16), (byte)(v >> 8), (byte)v);
    }

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        new SolidColorBrush(ToColor(value as string));

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// A theme + color name (ConverterParameter) → brush, from the theme's Global group.
public sealed class ThemeBrush : IValueConverter
{
    public static readonly ThemeBrush Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        new SolidColorBrush(value is ColorTheme t ? RgbaBrush.ToColor(t.Color(parameter as string ?? "")) : Colors.Gray);

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// A theme → the handful of colors shown on its card.
public sealed class ThemeSwatches : IValueConverter
{
    public static readonly ThemeSwatches Instance = new();
    static readonly string[] Preferred = ["Background", "BackgroundDark", "Text", "Selected", "Highlight", "Active", "Warning", "Alert"];

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not ColorTheme t) return Array.Empty<IBrush>();
        var colors = (t.Groups.FirstOrDefault(g => g.Name == "Global") ?? t.Groups.FirstOrDefault())?.Colors ?? [];
        var picked = Preferred.Select(n => colors.FirstOrDefault(c => c.Name == n)).OfType<ThemeColor>().ToList();
        foreach (var c in colors)
        {
            if (picked.Count >= 12) break;
            if (!picked.Contains(c)) picked.Add(c);
        }
        return picked.Take(12).Select(c => (IBrush)new SolidColorBrush(RgbaBrush.ToColor(c.Rgba))).ToList();
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public static class Conv
{
    public static readonly IValueConverter NotNull = new FuncValueConverter<object?, bool>(v => v != null);
    public static readonly IValueConverter IsNull = new FuncValueConverter<object?, bool>(v => v == null);
    public static readonly IValueConverter NotEmpty = new FuncValueConverter<object?, bool>(v => v switch
    {
        null => false, string s => s.Length > 0, System.Collections.ICollection c => c.Count > 0, _ => true,
    });
    public static readonly IValueConverter NotZero = new FuncValueConverter<int, bool>(n => n != 0);
    public static readonly IValueConverter Date = new FuncValueConverter<DateTime, string>(d => d == default ? "" : d.ToString("g"));
    public static readonly IValueConverter Interval = new FuncValueConverter<int, string>(m => m switch
    {
        0 => "Off", 60 => "Every hour", _ => $"Every {m} minutes",
    });
    public static readonly IValueConverter LogBrush = new FuncValueConverter<SyncKind, IBrush>(k => k switch
    {
        SyncKind.Error => Brushes.IndianRed, SyncKind.Conflict => Brushes.Orange, _ => Brushes.Gray,
    });
    public static readonly IValueConverter StatusBrush = new FuncValueConverter<string, IBrush>(s => s switch
    {
        "Installed" => Brushes.SeaGreen, "New" => new SolidColorBrush(Color.Parse("#E8A33D")), _ => Brushes.Gray,
    });
    public static readonly IValueConverter Modes = new FuncValueConverter<List<FixtureMode>, string>(m => m == null ? "" : string.Join("\n", m.Select(x => $"{x.Name} · {x.Channels} ch")));
}
