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

readonly REQUIRED_REVISIONS=(
    MPV_BUILD_REVISION FFMPEG_REVISION LIBASS_REVISION
    LIBPLACEBO_REVISION MPV_REVISION
)
for variable in "${REQUIRED_REVISIONS[@]}"; do
    unset "$variable"
done
source "$REPO_ROOT/$SOURCE_ENV"
for variable in "${REQUIRED_REVISIONS[@]}"; do
    [[ ${!variable:-} =~ ^[0-9a-f]{40}$ ]] || fail "$SOURCE_ENV must define $variable as a full Git revision."
done

readonly PROFILE_FILES=(ffmpeg_options libass_options libplacebo_options mpv_options)
for file in "${PROFILE_FILES[@]}"; do
    [[ -f "$REPO_ROOT/$BUILD_PROFILE/$file" ]] || fail "Build profile file not found: $BUILD_PROFILE/$file"
done

WORK_DIR="$(mktemp -d)"
WORK_DIR="$(cd -- "$WORK_DIR" && pwd -P)"
readonly WORK_DIR
readonly BUILD_DIR="$WORK_DIR/mpv-build"
readonly DIST_DIR="$WORK_DIR/dist"

cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

assert_clean_source() {
    local directory="$1"
    local status
    status="$(git -C "$directory" status --porcelain --untracked-files=all --ignore-submodules=none)"
    if [[ -n "$status" ]]; then
        git -C "$directory" status --short >&2
        fail "Source tree is not clean: $directory"
    fi
}

assert_git_revision() {
    local directory="$1"
    local expected="$2"

    local actual
    actual="$(git -C "$directory" rev-parse HEAD)"

    if [ "$actual" != "$expected" ]; then
        printf 'unexpected git revision in %s\n' "$directory" >&2
        printf 'expected: %s\n' "$expected" >&2
        printf 'actual:   %s\n' "$actual" >&2
        return 1
    fi
}

prepare_sources() {
    git clone \
        https://github.com/mpv-player/mpv-build.git \
        "$BUILD_DIR"

    git -C "$BUILD_DIR" \
        checkout --detach "$MPV_BUILD_REVISION"

    assert_git_revision \
        "$BUILD_DIR" \
        "$MPV_BUILD_REVISION"

    assert_clean_source "$BUILD_DIR"

    mkdir -p "$BUILD_DIR/config"

    printf '@%s\n' "$FFMPEG_REVISION" \
        > "$BUILD_DIR/config/branch-ffmpeg"

    printf '@%s\n' "$LIBASS_REVISION" \
        > "$BUILD_DIR/config/branch-libass"

    printf '@%s\n' "$LIBPLACEBO_REVISION" \
        > "$BUILD_DIR/config/branch-libplacebo"

    printf '@%s\n' "$MPV_REVISION" \
        > "$BUILD_DIR/config/branch-mpv"

    (
        cd "$BUILD_DIR"
        ./update --skip-selfupdate
    )

    assert_git_revision \
        "$BUILD_DIR/ffmpeg" \
        "$FFMPEG_REVISION"

    assert_git_revision \
        "$BUILD_DIR/libass" \
        "$LIBASS_REVISION"

    assert_git_revision \
        "$BUILD_DIR/libplacebo" \
        "$LIBPLACEBO_REVISION"

    assert_git_revision \
        "$BUILD_DIR/mpv" \
        "$MPV_REVISION"

    git -C "$BUILD_DIR/libplacebo" \
        submodule update \
        --init \
        --recursive \
        --checkout

    local component
    for component in ffmpeg libass libplacebo mpv; do
        assert_clean_source "$BUILD_DIR/$component"
    done
    git -C "$BUILD_DIR/libplacebo" submodule foreach --recursive '
        actual=$(git rev-parse HEAD) &&
        test "$actual" = "$sha1" &&
        status=$(git status --porcelain --untracked-files=all --ignore-submodules=none) &&
        test -z "$status"
    '

    local file
    for file in "${PROFILE_FILES[@]}"; do
        cp -- "$REPO_ROOT/$BUILD_PROFILE/$file" "$BUILD_DIR/$file"
    done
}

build_runtime() {
    docker build \
        --platform "$DOCKER_PLATFORM" \
        --file "$REPO_ROOT/$BUILDER_DOCKERFILE" \
        --tag "$BUILDER_IMAGE" \
        "$REPO_ROOT"

    docker run --rm \
        --platform "$DOCKER_PLATFORM" \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -v "$BUILD_DIR:/work" \
        -w /work \
        "$BUILDER_IMAGE" \
        sh -lc './clean && ./build -j"$(nproc)"'
}

assemble_dist() {
    mkdir -p "$DIST_DIR/bin" "$DIST_DIR/lib"
    cp -- "$BUILD_DIR/mpv/build/mpv" "$DIST_DIR/bin/mpv"

    # ldd resolves the transitive shared-library closure inside the builder.
    docker run --rm \
        --platform "$DOCKER_PLATFORM" \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -v "$BUILD_DIR:/work:ro" \
        -v "$DIST_DIR:/dist" \
        "$BUILDER_IMAGE" \
        bash -lc '
            set -euo pipefail

            dependencies=$(ldd /work/mpv/build/mpv)
            if [[ "$dependencies" == *"not found"* ]]; then
                printf "%s\n" "$dependencies" >&2
                exit 1
            fi

            printf "%s\n" "$dependencies" |
            awk "/=> \// { print \$3 }" |
            while read -r lib; do
                name=$(basename "$lib")

                case "$name" in
                    libc.so.*|\
                    libm.so.*|\
                    libpthread.so.*|\
                    libdl.so.*|\
                    librt.so.*|\
                    libresolv.so.*)
                        continue
                        ;;
                esac

                cp -L "$lib" "/dist/lib/$name"
            done
        '

    # Publish only after compilation, the contract, and dependency collection pass.
    rm -rf -- "$OUTPUT_DIR/dist"
    mv -- "$DIST_DIR" "$OUTPUT_DIR/dist"
}

assert_macro() {
    local file="$1"
    local macro="$2"
    local expected="$3"

    grep -qx \
        "#define $macro $expected" \
        "$file"
}

assert_component_count() {
    local pattern="$1"
    local expected="$2"

    local actual

    actual="$(
        grep -Ec "$pattern" \
            "$BUILD_DIR/ffmpeg_build/config_components.h" \
            || true
    )"

    if [ "$actual" != "$expected" ]; then
        printf \
            'unexpected FFmpeg component count: %s, expected %s\n' \
            "$actual" \
            "$expected" \
            >&2
        return 1
    fi
}

verify_ffmpeg_contract() {
    local components
    local config

    components="$BUILD_DIR/ffmpeg_build/config_components.h"
    config="$BUILD_DIR/ffmpeg_build/config.h"

    assert_macro "$components" CONFIG_AAC_DECODER 1
    assert_macro "$components" CONFIG_OPUS_DECODER 1

    assert_component_count \
        '^#define CONFIG_.*_DECODER 1$' \
        2

    assert_macro "$components" CONFIG_MATROSKA_DEMUXER 1
    assert_macro "$components" CONFIG_MOV_DEMUXER 1

    assert_component_count \
        '^#define CONFIG_.*_DEMUXER 1$' \
        2

    assert_macro "$components" CONFIG_FILE_PROTOCOL 1
    assert_macro "$components" CONFIG_HTTP_PROTOCOL 1
    assert_macro "$components" CONFIG_HTTPS_PROTOCOL 1
    assert_macro "$components" CONFIG_HTTPPROXY_PROTOCOL 1
    assert_macro "$components" CONFIG_TCP_PROTOCOL 1
    assert_macro "$components" CONFIG_TLS_PROTOCOL 1

    assert_component_count \
        '^#define CONFIG_.*_PROTOCOL 1$' \
        6

    assert_component_count \
        '^#define CONFIG_.*_ENCODER 1$' \
        0

    assert_component_count \
        '^#define CONFIG_.*_MUXER 1$' \
        0

    assert_component_count \
        '^#define CONFIG_.*_PARSER 1$' \
        0

    assert_component_count \
        '^#define CONFIG_.*_BSF 1$' \
        0

    assert_component_count \
        '^#define CONFIG_.*_FILTER 1$' \
        0

    assert_component_count \
        '^#define CONFIG_.*_HWACCEL 1$' \
        0

    assert_macro "$config" CONFIG_AVDEVICE 0
    assert_macro "$config" CONFIG_AVFILTER 1
    assert_macro "$config" CONFIG_SWSCALE 1
    assert_macro "$config" CONFIG_SWRESAMPLE 1

    assert_macro "$config" CONFIG_GNUTLS 1
    assert_macro "$config" CONFIG_OPENSSL 0
    assert_macro "$config" CONFIG_NONFREE 0
}

main() {
    prepare_sources
    build_runtime
    verify_ffmpeg_contract
    assemble_dist

    printf '\nmpv runtime build passed for %s.\ndist: %s\n' "$TARGET_ID" "$OUTPUT_DIR/dist"
}

main
