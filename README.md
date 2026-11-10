# MA3 Dashboard

A desktop dashboard for grandMA3 and grandMA2 onPC, for macOS and Windows. Website: https://jaylenjinx.github.io/ma3-dashboard/

- **Versions and showfiles:** launch any installed onPC build and see each version's shows. Shows can be duplicated, imported, or loaded on a running console over OSC.
- **grandMA2 on a Mac:** finds grandMA2 onPC in CrossOver bottles and in Parallels Desktop VMs. For Parallels, the dashboard reads showfiles and running state from inside the VM with `prlctl exec` while the VM is running, and can launch CleanStart, duplicate shows and open them in Explorer. Cloud Sync only includes Parallels showfiles when "Access Windows folders from Mac" is on and the VM's drive is mounted in /Volumes.
- **Library managers:** browse color themes, fixture types (GDTF, MA3 XML, MA2 pxml) and datapools.
- **Installers:** find and install new onPC releases.
- **Cloud Sync:** sync shows and library files between computers through a self-hosted server (`sync-server/`, deployable with Portainer).

| Folder | What |
| --- | --- |
| `Sources/`, `build-app.sh` | The macOS app (SwiftUI). `./build-app.sh` builds `build/MA3 Dashboard.app`. |
| `windows/` | The Windows app (.NET 10 + Avalonia). `windows/publish.sh` builds a self-contained exe. |
| `sync-server/` | The sync server (Node, no dependencies), set up for Docker, Cloudflare Tunnel and Portainer. |
| `docs/` | The website, served by GitHub Pages. |

Not affiliated with MA Lighting. grandMA3 and grandMA2 are trademarks of MA Lighting Technology GmbH.
