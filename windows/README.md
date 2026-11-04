# MA3 Dashboard for Windows

The Windows version of the dashboard, written in .NET 10 + Avalonia. It has the same features as the Mac app:
- grandMA3 and grandMA2 onPC versions and their showfiles: launch, LoadShow over OSC, duplicate, import
- the color theme, fixture type (GDTF / MA3 / MA2) and datapool managers
- onPC installers
- Cloud Sync against the same `sync-server`

## Build

```sh
./publish.sh
```

This runs on macOS or Windows. It produces `dist/MA3Dashboard/MA3Dashboard.exe`, a self-contained single file that needs no .NET install on the PC. It also produces `dist/MA3Dashboard-win-x64.zip`, which contains the exe and the `sync-server` setup files.

## Where it looks on Windows

| What | Path |
| --- | --- |
| grandMA3 data | `C:\ProgramData\MALightingTechnology\gma3_<x.y.z>\shared\shows`, `gma3_library` (can be changed under Cloud Sync → Folders) |
| grandMA3 programs | `Program Files\MALightingTechnology\gma3_<x.y.z>\bin\app_system.exe`, started with `HOSTTYPE=onPC` (Clean Start adds `CleanStart`), the same as MA's Start Menu shortcuts. The version comes from `app_gma3.exe` next to it. Without `app_system.exe` it falls back to `app_gma3.exe`, then to the shortcuts. |
| grandMA2 data | `C:\ProgramData\MA Lighting Technologies\grandma\gma2_V_<x.y.z>\shows` |
| grandMA2 program | `Program Files\MA Lighting Technologies\grandma\grandMA2 onPC <v>\gma2onpc.exe`; CleanStart runs it with `CLEANSTART NOLOAD` |
| Installers | `Downloads` and `…\MALightingTechnology\installation_packages` (`grandMA3_onPC_win_*.zip/.exe`, `gMA2onPC_v*.exe`) |
| App settings, sync state | `%AppData%\MA3Dashboard` (the sync token is encrypted with DPAPI) |

All of these were checked on a Windows 10 PC with grandMA3 onPC 2.3.2.0 and 2.4.2.2 and grandMA2 onPC 3.9.63.11 installed. Starting `app_gma3.exe` directly is not the same as MA's launcher: it runs as a generic "GMA3App" host with its own config folder (`gma3_<x.y.z>\gma3app`), takes about 25 s instead of 5 s, and opens an empty new show instead of the last one. `app_system.exe HOSTTYPE=onPC` starts `app_gma3.exe HOSTTYPE=onPC CALLEDFROM_APP_SYSTEM=1` and reopens the last show. Run `MA3Dashboard.exe --scan > scan.txt` on a PC to see what it detects (the output is UTF-8).

## Testing on a Mac

```sh
~/.dotnet/dotnet build MA3Dashboard && ~/.dotnet/dotnet MA3Dashboard/bin/Debug/net10.0/MA3Dashboard.dll
```

The Mac uses the same scanning code, with Mac paths. `--sync-once cfg.json` runs a headless sync using the same config format as the Swift app's `--sync-once`.
