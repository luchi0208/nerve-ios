#!/usr/bin/env bash
set -euo pipefail

# Build Nerve as a dynamic framework for iOS Simulator injection.
# Output: .build/inject/Nerve.framework/Nerve
#
# Usage:
#   ./scripts/build-framework.sh          # build if missing or stale
#   ./scripts/build-framework.sh --force  # always rebuild

NERVE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${NERVE_DIR}/.build/inject"
FRAMEWORK_DIR="${OUTPUT_DIR}/Nerve.framework"
DERIVED_DATA="${NERVE_DIR}/.build/framework-derived"

GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[nerve]${NC} $1"; }

# Check if rebuild is needed
if [[ "${1:-}" != "--force" && -f "${FRAMEWORK_DIR}/Nerve" ]]; then
    # Compare source timestamps against the framework binary
    newest_source=$(find "${NERVE_DIR}/Sources" -name '*.swift' -o -name '*.m' -o -name '*.c' -o -name '*.h' | xargs stat -f '%m' | sort -rn | head -1)
    framework_time=$(stat -f '%m' "${FRAMEWORK_DIR}/Nerve")
    if [[ "$newest_source" -le "$framework_time" ]]; then
        log "Nerve.framework is up to date."
        echo "${FRAMEWORK_DIR}/Nerve"
        exit 0
    fi
fi

log "Building Nerve.framework for iOS Simulator..."

# Build the dynamic library product
xcodebuild build \
    -scheme NerveDynamic \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${DERIVED_DATA}" \
    -configuration Debug \
    -quiet 2>&1 | tail -5

# Find the built framework in derived data
BUILT_FRAMEWORK=$(find "${DERIVED_DATA}" -path '*/Build/Products/Debug-iphonesimulator/PackageFrameworks/NerveDynamic.framework' -type d | head -1)

if [[ -z "$BUILT_FRAMEWORK" || ! -d "$BUILT_FRAMEWORK" ]]; then
    echo "Error: Could not find built NerveDynamic.framework" >&2
    exit 1
fi

# Copy to output location, renaming to Nerve.framework
rm -rf "${FRAMEWORK_DIR}"
mkdir -p "${OUTPUT_DIR}"
cp -R "${BUILT_FRAMEWORK}" "${FRAMEWORK_DIR}"

# Rename the binary inside the framework
if [[ -f "${FRAMEWORK_DIR}/NerveDynamic" ]]; then
    mv "${FRAMEWORK_DIR}/NerveDynamic" "${FRAMEWORK_DIR}/Nerve"
fi

log "Built: ${FRAMEWORK_DIR}/Nerve"
echo "${FRAMEWORK_DIR}/Nerve"
