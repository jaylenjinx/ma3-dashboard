# MA3 Dashboard

A desktop dashboard for grandMA3 and grandMA2 onPC, for macOS and Windows. Website: https://jaylenjinx.github.io/ma3-dashboard/

- **Versions and showfiles:** launch any installed onPC build and see each version's shows. Shows can be duplicated, imported, or loaded on a running console over OSC.
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
