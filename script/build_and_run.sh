#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
BUILD_ROOT="${SAPPHIRE_BUILD_ROOT:-$PROJECT_DIR/.local-build}"
APP_NAME="Sapphire"
BUNDLE_ID="com.cshariq.sapphire"
INSTALL_PATH="$HOME/Applications/$APP_NAME.app"

case "$MODE" in
  run|--debug|--logs|--telemetry|--verify|--build-only|--package-only|--install) ;;
  *) echo "usage: $0 [--debug|--logs|--telemetry|--verify|--build-only|--package-only|--install]" >&2; exit 2 ;;
esac

if [ "$MODE" = "--install" ] && [ -e "$INSTALL_PATH" ]; then
  echo "Refusing to overwrite existing app: $INSTALL_PATH" >&2
  exit 1
fi
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify) pkill -x "$APP_NAME" >/dev/null 2>&1 || true ;;
esac
mkdir -p "$BUILD_ROOT"
xcodebuild \
  -project "$PROJECT_DIR/Sapphire.xcodeproj" \
  -scheme Sapphire -configuration Debug \
  -xcconfig "$PROJECT_DIR/config/LocalPublic.xcconfig" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build

BUILT_APP="$BUILD_ROOT/DerivedData/Build/Products/Debug/$APP_NAME.app"
if [ "$MODE" = "--build-only" ]; then
  echo "Unsigned app: $BUILT_APP"
  exit 0
fi
STAGING_DIR="$(mktemp -d "$BUILD_ROOT/Staging.XXXXXX")"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
ditto "$BUILT_APP" "$APP_BUNDLE"

# Sign only this generated staging copy, deepest nested code first.
# Public extensions are packaged placeholders; this does not register them.
python3 - "$APP_BUNDLE" <<'PY'
from pathlib import Path
import subprocess, sys
app = Path(sys.argv[1])
main = app / 'Contents/MacOS/Sapphire'
bundles = [p for p in app.rglob('*') if p.is_dir() and p.suffix in
           {'.framework', '.appex', '.systemextension', '.driver', '.app', '.bundle'}]
for path in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
    if not path.is_file() or path.is_symlink() or path == main:
        continue
    with path.open('rb') as handle:
        magic = handle.read(4)
    if magic not in {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                     b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}:
        continue
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime',
                    '--timestamp=none', str(path)], check=True)
for path in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime',
                    '--timestamp=none', str(path)], check=True)
PY
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$PROJECT_DIR/config/LocalRuntime.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
echo "Signed local app: $APP_BUNDLE"

initialize_first_use_preferences() {
  if ! defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    defaults write "$BUNDLE_ID" launchAtLogin -bool false
    defaults write "$BUNDLE_ID" automaticUpdateChecksEnabled -bool false
    defaults write "$BUNDLE_ID" automaticallyDownloadSapphireUpdates -bool false
  fi
}

case "$MODE" in
  --package-only) exit 0 ;;
  --install)
    mkdir -p "$HOME/Applications"
    # Recheck after building so another process cannot be silently overwritten.
    [ ! -e "$INSTALL_PATH" ] || { echo "App now exists: $INSTALL_PATH" >&2; exit 1; }
    ditto "$APP_BUNDLE" "$INSTALL_PATH"
    codesign --verify --deep --strict --verbose=4 "$INSTALL_PATH"
    initialize_first_use_preferences
    echo "Installed without launch: $INSTALL_PATH"
    ;;
  --debug)
    initialize_first_use_preferences
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|--telemetry)
    initialize_first_use_preferences
    open -n "$APP_BUNDLE"
    if [ "$MODE" = "--logs" ]; then
      /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    else
      /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    fi
    ;;
  --verify)
    initialize_first_use_preferences
    open -n "$APP_BUNDLE"
    python3 - "$APP_NAME" <<'PY'
import subprocess, sys, time
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    if subprocess.run(['pgrep', '-x', sys.argv[1]], stdout=subprocess.DEVNULL).returncode == 0:
        print('Launch process exists; UI acceptance remains separate.')
        break
    time.sleep(0.2)
else:
    raise SystemExit('App process was not observed after launch.')
PY
    ;;
  run)
    initialize_first_use_preferences
    open -n "$APP_BUNDLE"
    ;;
esac
