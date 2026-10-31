#!/bin/sh
# Builds the Windows app from any OS: a self-contained MA3Dashboard.exe (no .NET install needed on the PC)
# plus the sync-server setup files, zipped as dist/MA3Dashboard-win-x64.zip.
set -e
cd "$(dirname "$0")"
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
rm -rf dist/MA3Dashboard
"$DOTNET" publish MA3Dashboard/MA3Dashboard.csproj -c Release -r win-x64 --self-contained \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
  -p:DebugType=none -o dist/MA3Dashboard
rm -f dist/MA3Dashboard/*.pdb dist/MA3Dashboard-win-x64.zip
(cd dist && zip -qr MA3Dashboard-win-x64.zip MA3Dashboard)
ls -la dist/MA3Dashboard dist/MA3Dashboard-win-x64.zip
