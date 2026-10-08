#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
PROJECT_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
DERIVED_DATA="${SAPPHIRE_TEST_DERIVED_DATA:-$PROJECT_DIR/.local-build/TestDerivedData}"
PACKAGES_DIR="${SAPPHIRE_TEST_PACKAGES_DIR:-$PROJECT_DIR/.local-build/SourcePackages}"

case "$MODE" in
  build) ACTION=build-for-testing ;;
  test) ACTION=test-without-building ;;
  *) echo "usage: $0 [build|test]" >&2; exit 2 ;;
esac

# Build the complete existing test target without test exclusions.
# The test action requires a previously built, runnable test host; this script
# does not install an app, alter signing policy, or grant system permissions.
xcodebuild \
  -project "$PROJECT_DIR/Sapphire.xcodeproj" \
  -scheme Sapphire -configuration Debug \
  -xcconfig "$PROJECT_DIR/config/LocalPublic.xcconfig" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PACKAGES_DIR" \
  -onlyUsePackageVersionsFromResolvedFile \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO "$ACTION"
