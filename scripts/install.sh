#!/bin/sh
# Installs a downloaded Forkcast release: run it from the unzipped folder with
#   sh install.sh
# It copies Forkcast.app to /Applications, links the `forkcast` CLI and man page into ~/.local, and launches the app.
# Override locations with APPS_DIR=… BIN_DIR=… MAN_DIR=… sh install.sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
APPS_DIR=${APPS_DIR:-/Applications}
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
MAN_DIR=${MAN_DIR:-$HOME/.local/share/man/man1}
APP="$APPS_DIR/Forkcast.app"

[ -d "$HERE/Forkcast.app" ] || { echo "install.sh: Forkcast.app not found next to this script" >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "install.sh: Forkcast needs an Apple Silicon Mac" >&2; exit 1; }

osascript -e 'quit app "Forkcast"' >/dev/null 2>&1 || true
pkill -x Forkcast >/dev/null 2>&1 || true
sleep 1

rm -rf "$APP"
ditto "$HERE/Forkcast.app" "$APP"

# Builds that aren't signed with a Developer ID and notarized are blocked by Gatekeeper once downloaded.
# Only remove the quarantine flag in that case (notarized builds pass Gatekeeper on their own).
if ! spctl --assess --type execute "$APP" >/dev/null 2>&1; then
  echo "This build isn't notarized; removing the download quarantine flag so macOS will open it."
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
fi

mkdir -p "$BIN_DIR" "$MAN_DIR"
ln -sf "$APP/Contents/Helpers/forkcast" "$BIN_DIR/forkcast"
ln -sf "$APP/Contents/Resources/forkcast.1" "$MAN_DIR/forkcast.1"

open "$APP"
echo "Installed $APP"
echo "CLI: $BIN_DIR/forkcast   ·   docs: forkcast help · man forkcast"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Note: add $BIN_DIR to your PATH to use the forkcast command." ;; esac
