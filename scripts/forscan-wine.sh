#!/usr/bin/env bash
# Install and run the Windows FORScan build under Wine / CrossOver on macOS,
# with COM1 mapped to your USB OBD adapter.
#
#   scripts/forscan-wine.sh install <FORScanSetup.exe | FORScanSetup.zip (split .zip+.z01 ok)>
#   scripts/forscan-wine.sh map [/dev/cu.usbserial-XXXX]   # (re)map COM1 to the adapter
#   scripts/forscan-wine.sh run
#
# Env: WINEPREFIX (default ~/.wine-forscan), WINE (path to wine binary, auto-detected)
#
# Reliability note: a Windows VM (Parallels / VMware Fusion) is the dependable route.
# Wine is fine for reading codes/live data; do NOT program modules under Wine.
set -euo pipefail

PREFIX="${WINEPREFIX:-$HOME/.wine-forscan}"
export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all}"

find_wine() {
  if [[ -n "${WINE:-}" ]]; then echo "$WINE"; return; fi
  for c in wine wine64 \
           "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine" \
           "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine" \
           "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return; fi
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  return 1
}

need_wine() {
  if ! WINE_BIN="$(find_wine)"; then
    cat <<MSG
No Wine found. Options (pick one):
  • CrossOver (paid, supported):  https://www.codeweavers.com/crossover
  • Gcenx Wine builds via Homebrew:
        brew tap gcenx/wine && brew install --cask --no-quarantine wine-crossover
  On Apple Silicon also run:  softwareupdate --install-rosetta --agree-to-license
Then re-run, or set WINE=/path/to/wine.
MSG
    exit 1
  fi
  export WINE_BIN
}

detect_port() {
  local p
  p="$(ls /dev/cu.usbserial* /dev/cu.usbmodem* /dev/cu.OBDLink* /dev/cu.wchusbserial* 2>/dev/null | head -n1 || true)"
  echo "$p"
}

cmd_map() {
  local port="${1:-$(detect_port)}"
  [[ -n "$port" ]] || { echo "No adapter found in /dev/cu.*. Plug in the USB adapter (or pair Bluetooth) and retry."; exit 1; }
  mkdir -p "$PREFIX/dosdevices"
  ln -sfn "$port" "$PREFIX/dosdevices/com1"
  echo "COM1 -> $port   (select COM1 in FORScan › Settings › Connection)"
}

cmd_install() {
  local src="${1:?path to FORScanSetup .exe or .zip}"
  need_wine
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  local exe="$src"
  if [[ "$src" == *.zip ]]; then
    local base="${src%.zip}"
    if [[ -f "$base.z01" ]]; then
      echo "Joining split archive…"
      zip -s 0 "$src" --out "$tmp/joined.zip" >/dev/null
      unzip -q "$tmp/joined.zip" -d "$tmp"
    else
      unzip -q "$src" -d "$tmp"
    fi
    exe="$(ls "$tmp"/*.exe | head -n1)"
  fi
  [[ -f "$exe" ]] || { echo "Installer not found: $exe"; exit 1; }
  echo "Installer: $(basename "$exe")  sha256=$(shasum -a 256 "$exe" | cut -d' ' -f1)"

  echo "Creating Wine prefix at $PREFIX…"
  "$WINE_BIN" wineboot --init >/dev/null 2>&1 || true
  echo "Running FORScan installer silently (Inno Setup)…"
  "$WINE_BIN" "$exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- || {
    echo "Silent install failed; launching interactive installer."; "$WINE_BIN" "$exe"; }
  cmd_map "" || true
  echo "Installed. Start with: $0 run"
}

cmd_run() {
  need_wine
  local exe
  exe="$(find "$PREFIX/drive_c" -iname 'FORScan.exe' 2>/dev/null | head -n1)"
  [[ -n "$exe" ]] || { echo "FORScan.exe not found in $PREFIX. Run: $0 install <installer>"; exit 1; }
  [[ -e "$PREFIX/dosdevices/com1" ]] || cmd_map "" || true
  cd "$(dirname "$exe")"
  exec "$WINE_BIN" "$exe"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  map) shift; cmd_map "${1:-}" ;;
  run) cmd_run ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
