#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: %s <target-id> /exact/path/to/archive.tar.zst\n' "${0##*/}" >&2
}

if [[ $# -ne 2 ]]; then
    usage
    fail 'Expected exactly two arguments: target ID and exact archive path.'
fi

# Match the safe target ID syntax used by build-target.sh.
if [[ ! $1 =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    usage
    fail "Invalid target ID '$1'; use lowercase letters, digits, underscores, or hyphens, starting with a letter or digit."
fi

readonly REQUESTED_TARGET="$1"
readonly ARCHIVE_ARGUMENT="$2"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly REPO_ROOT
readonly TARGET_CONFIG="$REPO_ROOT/targets/$REQUESTED_TARGET/target.env"

[[ -f "$TARGET_CONFIG" ]] || fail "Unknown target '$REQUESTED_TARGET': config file not found: $TARGET_CONFIG"

# Day 8 needs only the target identity from the trusted repository config.
unset TARGET_ID
source "$TARGET_CONFIG" >&2 || fail "Could not load target config: $TARGET_CONFIG"
[[ -n ${TARGET_ID:-} ]] || fail "$TARGET_CONFIG must define a non-empty TARGET_ID."
[[ "$TARGET_ID" == "$REQUESTED_TARGET" ]] || fail "Config TARGET_ID '$TARGET_ID' does not match requested target '$REQUESTED_TARGET'."
readonly TARGET_ID

[[ -f "$ARCHIVE_ARGUMENT" ]] || fail "Archive is not an existing regular file: $ARCHIVE_ARGUMENT"
ARCHIVE_DIR="$(cd -- "$(dirname -- "$ARCHIVE_ARGUMENT")" && pwd -P)" || fail 'Could not resolve archive directory.'
readonly ARCHIVE_DIR
readonly ARCHIVE_NAME="${ARCHIVE_ARGUMENT##*/}"
readonly ARCHIVE_PATH="$ARCHIVE_DIR/$ARCHIVE_NAME"
readonly CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
[[ -f "$CHECKSUM_PATH" ]] || fail "Checksum is not an existing regular file: $CHECKSUM_PATH"

# Validate package-target.sh's single basename-based record before letting
# sha256sum -c read it, so checksum filenames cannot redirect verification.
checksum_record="$(cat -- "$CHECKSUM_PATH")" || fail "Could not read checksum: $CHECKSUM_PATH"
[[ "$checksum_record" =~ ^([0-9a-f]{64})\ \  ]] || fail "Invalid SHA-256 checksum record: $CHECKSUM_PATH"
[[ "$checksum_record" == "${BASH_REMATCH[1]}  ${ARCHIVE_NAME}" ]] || fail "Checksum must contain one record naming exactly the supplied archive basename: $CHECKSUM_PATH"
if ! (
    cd -- "$ARCHIVE_DIR" || exit 1
    printf '%s\n' "$checksum_record" | sha256sum -c --strict -
); then
    fail "SHA-256 checksum verification failed: $ARCHIVE_PATH"
fi

WORK_DIR="$(mktemp -d)" || fail 'Could not create temporary verification directory.'
readonly WORK_DIR
cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep the listing outside the extraction root. Ignore inherited tar options so
# they cannot change member names, extraction paths, or extraction behavior.
unset TAR_OPTIONS
readonly EXTRACT_DIR="$WORK_DIR/runtime"
mkdir -- "$EXTRACT_DIR" || fail 'Could not create temporary extraction directory.'

# --absolute-names preserves unsafe prefixes for inspection, never extraction.
# Escape control characters so a member containing a newline stays on one line.
if ! LC_ALL=C tar --zstd --list --absolute-names --quoting-style=escape \
    --file "$ARCHIVE_PATH" > "$WORK_DIR/members"; then
    fail "Archive listing failed: $ARCHIVE_PATH"
fi
while IFS= read -r member; do
    case "/$member/" in
        //*|*/../*)
            fail "Unsafe archive member path: $member"
            ;;
    esac
done < "$WORK_DIR/members"

# GNU tar's normal link/path protections remain enabled during extraction.
if ! tar --zstd --extract --no-same-owner --no-same-permissions \
    --directory "$EXTRACT_DIR" --file "$ARCHIVE_PATH"; then
    fail "Archive extraction failed: $ARCHIVE_PATH"
fi

shopt -s nullglob dotglob
for entry in "$EXTRACT_DIR/"*; do
    case "${entry##*/}" in
        bin|lib) ;;
        *) fail "Unexpected top-level artifact entry: ${entry##*/}" ;;
    esac
done
for directory in bin lib; do
    [[ -d "$EXTRACT_DIR/$directory" && ! -L "$EXTRACT_DIR/$directory" ]] || fail "Artifact must contain a real $directory directory."
done
[[ -f "$EXTRACT_DIR/bin/mpv" && ! -L "$EXTRACT_DIR/bin/mpv" && -x "$EXTRACT_DIR/bin/mpv" ]] || fail 'Artifact bin/mpv must be an executable regular file, not a symlink.'

# Match the packager's one-binary contract, including hidden entries.
bin_entries=("$EXTRACT_DIR/bin/"*)
[[ ${#bin_entries[@]} -eq 1 && "${bin_entries[0]}" == "$EXTRACT_DIR/bin/mpv" ]] || fail 'Artifact bin must contain exactly one entry: mpv.'

printf 'Day 8 archive safety and structure verification passed for %s.\nArchive: %s\n' "$TARGET_ID" "$ARCHIVE_PATH"
