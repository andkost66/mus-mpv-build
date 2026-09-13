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

readonly REQUIRED_VARIABLES=(TARGET_ID ARTIFACT_TARGET SOURCE_ENV)
# Require values from the trusted repository config, not inherited environment.
for variable in "${REQUIRED_VARIABLES[@]}"; do
    unset "$variable"
done
source "$TARGET_CONFIG" >&2
for variable in "${REQUIRED_VARIABLES[@]}"; do
    [[ -n ${!variable:-} ]] || fail "$TARGET_CONFIG must define a non-empty $variable."
done

[[ "$TARGET_ID" == "$REQUESTED_TARGET" ]] || fail "Config TARGET_ID '$TARGET_ID' does not match requested target '$REQUESTED_TARGET'."
[[ "$ARTIFACT_TARGET" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Invalid ARTIFACT_TARGET: $ARTIFACT_TARGET"
readonly TARGET_ID ARTIFACT_TARGET SOURCE_ENV

case "/$SOURCE_ENV/" in
    //*|*/../*)
        fail "SOURCE_ENV must be repository-relative without '..' components: $SOURCE_ENV"
        ;;
esac
[[ -f "$REPO_ROOT/$SOURCE_ENV" ]] || fail "SOURCE_ENV file not found: $REPO_ROOT/$SOURCE_ENV"
SOURCE_CONFIG="$(realpath -- "$REPO_ROOT/$SOURCE_ENV")"
readonly SOURCE_CONFIG
[[ "$SOURCE_CONFIG" == "$REPO_ROOT/"* ]] || fail 'SOURCE_ENV must resolve inside the repository.'

unset MPV_VERSION
source "$SOURCE_CONFIG" >&2
[[ ${MPV_VERSION:-} =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "$SOURCE_ENV must define a non-empty, filename-safe MPV_VERSION."
readonly MPV_VERSION

readonly OUTPUT_DIR="$REPO_ROOT/out/$REQUESTED_TARGET"
readonly DIST_DIR="$OUTPUT_DIR/dist"
[[ -d "$DIST_DIR" && ! -L "$DIST_DIR" ]] || fail "Runtime dist directory not found or is a symlink: $DIST_DIR"
for directory in bin lib; do
    [[ -d "$DIST_DIR/$directory" && ! -L "$DIST_DIR/$directory" ]] || fail "Runtime directory not found or is a symlink: $DIST_DIR/$directory"
done
[[ -f "$DIST_DIR/bin/mpv" && ! -L "$DIST_DIR/bin/mpv" && -r "$DIST_DIR/bin/mpv" && -s "$DIST_DIR/bin/mpv" && -x "$DIST_DIR/bin/mpv" ]] || fail 'dist/bin/mpv must be a readable, non-empty, executable regular file, not a symlink.'

# Include hidden entries when checking the one-binary runtime contract.
shopt -s nullglob dotglob
bin_entries=("$DIST_DIR/bin/"*)
[[ ${#bin_entries[@]} -eq 1 && "${bin_entries[0]}" == "$DIST_DIR/bin/mpv" ]] || fail 'dist/bin must contain exactly one entry: mpv.'
unwanted_entry="$(find "$DIST_DIR/bin" "$DIST_DIR/lib" -name yt-dlp -print -quit)"
[[ -z "$unwanted_entry" ]] || fail 'Runtime directories must not contain yt-dlp.'

revision="$(git -C "$REPO_ROOT" rev-parse HEAD)"
[[ "$revision" =~ ^[0-9a-f]{40,64}$ ]] || fail 'Git HEAD did not resolve to a full revision.'
readonly short_sha="${revision:0:12}"
readonly archive="mpv-${MPV_VERSION}-${ARTIFACT_TARGET}-rev.${short_sha}.tar.zst"
readonly ARTIFACT_DIR="$OUTPUT_DIR/artifacts"
[[ "$(realpath -m -- "$ARTIFACT_DIR")" == "$ARTIFACT_DIR" ]] || fail 'Artifact directory must not resolve through symlinks.'
mkdir -p -- "$ARTIFACT_DIR"

WORK_DIR="$(mktemp -d "$ARTIFACT_DIR/.package.XXXXXXXX")"
readonly WORK_DIR
cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

printf 'Packaging runtime for %s...\n' "$TARGET_ID" >&2
tar \
    --directory "$DIST_DIR" \
    --create \
    --file - \
    bin lib |
    zstd \
        -T0 \
        -o "$WORK_DIR/$archive" >&2

(
    cd -- "$WORK_DIR"
    sha256sum "$archive" > "${archive}.sha256"
)
mv -fT -- "$WORK_DIR/$archive" "$ARTIFACT_DIR/$archive"
mv -fT -- "$WORK_DIR/${archive}.sha256" "$ARTIFACT_DIR/${archive}.sha256"

printf '%s\n' "$ARTIFACT_DIR/$archive"
