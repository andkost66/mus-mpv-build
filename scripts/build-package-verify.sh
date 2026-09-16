#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: %s <target-id>\n' "${0##*/}" >&2
}

if [[ $# -ne 1 ]]; then
    usage
    fail 'Expected exactly one explicit target ID.'
fi

# Match the safe target ID syntax used by build-target.sh.
if [[ ! $1 =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    usage
    fail "Invalid target ID '$1'; use lowercase letters, digits, underscores, or hyphens, starting with a letter or digit."
fi

readonly REQUESTED_TARGET="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly REPO_ROOT
readonly TARGET_CONFIG="$REPO_ROOT/targets/$REQUESTED_TARGET/target.env"

[[ -f "$TARGET_CONFIG" ]] || fail "Unknown target '$REQUESTED_TARGET': config file not found: $TARGET_CONFIG"

"$SCRIPT_DIR/build-target.sh" "$REQUESTED_TARGET"

# The packager writes only the exact archive path to stdout.
# Assign before readonly so a packaging failure retains its exit status.
ARCHIVE_PATH="$("$SCRIPT_DIR/package-target.sh" "$REQUESTED_TARGET")"
readonly ARCHIVE_PATH

"$SCRIPT_DIR/verify-artifact.sh" "$REQUESTED_TARGET" "$ARCHIVE_PATH"

ARCHIVE_SHA256="$(sha256sum < "$ARCHIVE_PATH")"
readonly ARCHIVE_SHA256
printf '\nBuild, package and verification passed.\nTarget: %s\nArchive: %s\nSHA-256: %s\n' \
    "$REQUESTED_TARGET" "$ARCHIVE_PATH" "${ARCHIVE_SHA256%% *}"
