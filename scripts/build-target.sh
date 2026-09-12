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

# IDs start with a lowercase ASCII letter or digit, followed by those
# characters, underscores, or hyphens. No path separators or dot segments.
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

readonly REQUIRED_VARIABLES=(
    TARGET_ID
    ARTIFACT_TARGET
    ARCH
    DOCKER_PLATFORM
    EXPECTED_MACHINE
    BUILDER_IMAGE
    BUILDER_DOCKERFILE
    SOURCE_ENV
    BUILD_PROFILE
    GLIBC_BASELINE
    PORTABILITY_IMAGES
)

# Require values from the trusted repository config, not inherited environment.
for variable in "${REQUIRED_VARIABLES[@]}"; do
    unset "$variable"
done
source "$TARGET_CONFIG"

for variable in "${REQUIRED_VARIABLES[@]}"; do
    [[ -n ${!variable:-} ]] || fail "$TARGET_CONFIG must define a non-empty $variable."
done

[[ "$TARGET_ID" == "$REQUESTED_TARGET" ]] || fail "Config TARGET_ID '$TARGET_ID' does not match requested target '$REQUESTED_TARGET'."

for variable in BUILDER_DOCKERFILE SOURCE_ENV BUILD_PROFILE; do
    path="${!variable}"
    case "/$path/" in
        //*|*/../*)
            fail "$variable must be repository-relative without '..' components: $path"
            ;;
    esac

    if [[ "$variable" == BUILD_PROFILE ]]; then
        [[ -d "$REPO_ROOT/$path" ]] || fail "$variable directory not found: $REPO_ROOT/$path"
    else
        [[ -f "$REPO_ROOT/$path" ]] || fail "$variable file not found: $REPO_ROOT/$path"
    fi
done

readonly OUTPUT_DIR="$REPO_ROOT/out/$REQUESTED_TARGET"
mkdir -p -- "$OUTPUT_DIR"

printf 'Target config validated: %s\nOutput directory: %s\n' "$REQUESTED_TARGET" "$OUTPUT_DIR"
