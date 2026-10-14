#!/bin/sh
# Builds and installs OBS Touch Control for the current user (no root needed).
#   ./install.sh              install into ~/.local
#   ./install.sh --uninstall  remove it again (config in ~/.config is kept)
# Set PREFIX to install elsewhere.
set -eu

APP_ID=io.github.akusen.ObsTouchControl
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin/obs-touch-control"
ICON="$PREFIX/share/icons/hicolor/scalable/apps/$APP_ID.svg"
DESKTOP="$PREFIX/share/applications/$APP_ID.desktop"

refresh_caches() {
    command -v update-desktop-database >/dev/null && update-desktop-database "$PREFIX/share/applications" || true
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -f -t "$PREFIX/share/icons/hicolor" || true
}

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$BIN" "$ICON" "$DESKTOP"
    refresh_caches
    echo "OBS Touch Control rimosso."
    exit 0
fi

cd "$(dirname "$0")"
cargo build --release

install -Dm755 target/release/obs-touch-control "$BIN"
install -Dm644 "data/$APP_ID.svg" "$ICON"
mkdir -p "$(dirname "$DESKTOP")"
# Absolute Exec path: launchers do not always have ~/.local/bin in PATH.
sed "s|^Exec=.*|Exec=$BIN|" "data/$APP_ID.desktop" > "$DESKTOP"
chmod 644 "$DESKTOP"
refresh_caches

echo "Installato: $BIN"
echo "Avviabile dal menu applicazioni come \"OBS Touch Control\"."
