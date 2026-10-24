#!/usr/bin/env bash
set -euo pipefail

PKG="foxyvpn"
VER="1.0.0"
BUNDLE="build/linux/x64/release/bundle"
STAGE="build/deb/${PKG}_${VER}_amd64"

if [ ! -d "$BUNDLE" ]; then
  echo "Linux build not found. Run flutter build linux --release first."
  exit 1
fi

mapfile -t BINS < <(
  find "$BUNDLE" -maxdepth 1 -type f -executable
)

if [ "${#BINS[@]}" -ne 1 ]; then
  echo "Could not identify a single executable in $BUNDLE"
  echo "Executables found: ${#BINS[@]}"
  ls -la "$BUNDLE"
  exit 1
fi

BIN="$(basename "${BINS[0]}")"

rm -rf "$STAGE"
mkdir -p \
  "$STAGE/DEBIAN" \
  "$STAGE/opt/$PKG" \
  "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications"

cp -a "$BUNDLE/." "$STAGE/opt/$PKG/"

ln -s "/opt/$PKG/$BIN" "$STAGE/usr/bin/$PKG"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: foxyvpn
Version: 1.0.0
Section: net
Priority: optional
Architecture: amd64
Maintainer: FoxyVPN Project
Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libstdc++6, libgcc-s1, libc6
Description: FoxyVPN Linux desktop client
 Flutter-based VPN client for Linux.
CONTROL

cat > "$STAGE/usr/share/applications/foxyvpn.desktop" <<DESKTOP
[Desktop Entry]
Name=FoxyVPN
Comment=FoxyVPN Linux Client
Exec=/opt/foxyvpn/$BIN
Icon=network-vpn
Terminal=false
Type=Application
Categories=Network;
StartupNotify=true
DESKTOP

dpkg-deb --build --root-owner-group \
  "$STAGE" "build/foxyvpn_${VER}_amd64.deb"

echo "Package created: build/foxyvpn_${VER}_amd64.deb"
