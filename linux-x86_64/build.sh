#!/usr/bin/env bash

set -euo pipefail

TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TARGET_DIR/.." && pwd)"

DIST_DIR="$REPO_ROOT/dist"
FIXTURES_DIR="$REPO_ROOT/fixtures"

BUILDER_IMAGE="${BUILDER_IMAGE:-mus-mpv-builder:glibc-2.31}"
BUILDER_DOCKERFILE="${BUILDER_DOCKERFILE:-$TARGET_DIR/Dockerfile}"
BUILDER_PLATFORM="${BUILDER_PLATFORM:-}"
DOCKER_PLATFORM_ARGS=()

if [ -n "$BUILDER_PLATFORM" ]; then
    DOCKER_PLATFORM_ARGS=(--platform "$BUILDER_PLATFORM")
fi

source "$TARGET_DIR/source.env"

WORK_DIR="$(mktemp -d)"
BUILD_DIR="$WORK_DIR/mpv-build"

HTTPS_PID=""
MPV_PID=""

cleanup() {
    if [ -n "$MPV_PID" ]; then
        kill "$MPV_PID" 2>/dev/null || true
        wait "$MPV_PID" 2>/dev/null || true
    fi

    if [ -n "$HTTPS_PID" ]; then
        kill "$HTTPS_PID" 2>/dev/null || true
        wait "$HTTPS_PID" 2>/dev/null || true
    fi

    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

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

    if [ -n "$(git -C "$BUILD_DIR/libplacebo" status --porcelain)" ]; then
        echo "libplacebo source tree is not clean after source preparation" >&2
        git -C "$BUILD_DIR/libplacebo" status --short >&2
        return 1
    fi

    cp "$TARGET_DIR/ffmpeg_options" \
        "$BUILD_DIR/ffmpeg_options"

    cp "$TARGET_DIR/libass_options" \
        "$BUILD_DIR/libass_options"

    cp "$TARGET_DIR/libplacebo_options" \
        "$BUILD_DIR/libplacebo_options"

    cp "$TARGET_DIR/mpv_options" \
        "$BUILD_DIR/mpv_options"
}

build_runtime() {
    docker build \
        "${DOCKER_PLATFORM_ARGS[@]}" \
        --file "$BUILDER_DOCKERFILE" \
        --tag "$BUILDER_IMAGE" \
        "$TARGET_DIR"

    docker run --rm \
        "${DOCKER_PLATFORM_ARGS[@]}" \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -v "$BUILD_DIR:/work" \
        -w /work \
        "$BUILDER_IMAGE" \
        sh -lc './clean && ./build -j"$(nproc)"'
}

assemble_dist() {
    rm -rf "$DIST_DIR"

    mkdir -p \
        "$DIST_DIR/bin" \
        "$DIST_DIR/lib"

    cp \
        "$BUILD_DIR/mpv/build/mpv" \
        "$DIST_DIR/bin/mpv"

    docker run --rm \
        "${DOCKER_PLATFORM_ARGS[@]}" \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -v "$BUILD_DIR:/work:ro" \
        -v "$DIST_DIR:/dist" \
        "$BUILDER_IMAGE" \
        sh -lc '
            set -eu

            ldd /work/mpv/build/mpv |
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
}

run_mpv() {
    LD_LIBRARY_PATH="$DIST_DIR/lib" \
        "$DIST_DIR/bin/mpv" \
        "$@"
}

verify_runtime() {
    run_mpv \
        --no-config \
        --version |
        grep -F "mpv v${MPV_VERSION}"

    local audio_outputs

    audio_outputs="$(
        run_mpv \
            --no-config \
            --ao=help \
            2>&1
    )"

    grep -F 'pulse' <<<"$audio_outputs"
    grep -F 'alsa' <<<"$audio_outputs"
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

verify_media() {
    run_mpv \
        --no-config \
        --no-video \
        --ao=null \
        "$FIXTURES_DIR/opus.webm"

    run_mpv \
        --no-config \
        --no-video \
        --ao=null \
        "$FIXTURES_DIR/aac.m4a"
}

verify_portability() {
    local image

    for image in \
        debian:11-slim \
        ubuntu:20.04 \
        ubuntu:22.04
    do
        docker run --rm \
            --network none \
            -v "$DIST_DIR:/opt/mus:ro" \
            -v "$FIXTURES_DIR:/fixtures:ro" \
            "$image" \
            sh -lc '
                set -eu

                export LD_LIBRARY_PATH=/opt/mus/lib

                /opt/mus/bin/mpv \
                    --no-config \
                    --no-video \
                    --ao=null \
                    /fixtures/opus.webm

                /opt/mus/bin/mpv \
                    --no-config \
                    --no-video \
                    --ao=null \
                    /fixtures/aac.m4a
            '
    done
}

verify_https() {
    local https_dir="$WORK_DIR/https"

    mkdir -p "$https_dir"

    cp \
        "$FIXTURES_DIR/aac.m4a" \
        "$https_dir/"

    openssl req \
        -x509 \
        -newkey rsa:2048 \
        -sha256 \
        -nodes \
        -days 1 \
        -keyout "$https_dir/key.pem" \
        -out "$https_dir/cert.pem" \
        -subj '/CN=localhost' \
        -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'

    HTTPS_DIR="$https_dir" \
    python3 - <<'PY' &
import http.server
import os
import ssl

directory = os.environ["HTTPS_DIR"]

os.chdir(directory)

server = http.server.ThreadingHTTPServer(
    ("127.0.0.1", 8443),
    http.server.SimpleHTTPRequestHandler,
)

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(
    certfile=f"{directory}/cert.pem",
    keyfile=f"{directory}/key.pem",
)

server.socket = context.wrap_socket(
    server.socket,
    server_side=True,
)

server.serve_forever()
PY

    HTTPS_PID=$!

    local ready=false

    for _ in {1..100}; do
        if python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.connect(("127.0.0.1", 8443))
PY
        then
            ready=true
            break
        fi

        sleep 0.05
    done

    if [ "$ready" != true ]; then
        echo "HTTPS smoke server did not become ready" >&2
        return 1
    fi

    run_mpv \
        --no-config \
        --no-video \
        --ao=null \
        --tls-verify=yes \
        --tls-ca-file="$https_dir/cert.pem" \
        https://localhost:8443/aac.m4a

    kill "$HTTPS_PID"
    wait "$HTTPS_PID" 2>/dev/null || true
    HTTPS_PID=""
}

verify_ipc() {
    local socket_path="$WORK_DIR/mpv.sock"
    local log_path="$WORK_DIR/mpv.log"

    LD_LIBRARY_PATH="$DIST_DIR/lib" \
        "$DIST_DIR/bin/mpv" \
        --no-config \
        --no-video \
        --ao=null \
        --idle=yes \
        --input-ipc-server="$socket_path" \
        >"$log_path" 2>&1 &

    MPV_PID=$!

    local ready=false

    for _ in {1..100}; do
        if [ -S "$socket_path" ]; then
            ready=true
            break
        fi

        if ! kill -0 "$MPV_PID" 2>/dev/null; then
            cat "$log_path" >&2
            return 1
        fi

        sleep 0.05
    done

    if [ "$ready" != true ]; then
        cat "$log_path" >&2
        echo "mpv IPC socket did not become ready" >&2
        return 1
    fi

    SOCKET_PATH="$socket_path" \
    FIXTURE="$FIXTURES_DIR/aac.m4a" \
    MPV_VERSION="$MPV_VERSION" \
    python3 - <<'PY'
import json
import os
import socket

socket_path = os.environ["SOCKET_PATH"]
fixture = os.environ["FIXTURE"]
expected_version = os.environ["MPV_VERSION"]

commands = [
    (1, ["get_property", "mpv-version"]),
    (2, ["loadfile", fixture]),
    (3, ["set_property", "pause", True]),
    (4, ["get_property", "pause"]),
    (5, ["set_property", "pause", False]),
    (6, ["quit"]),
]

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.connect(socket_path)

    stream = sock.makefile("rwb")

    for request_id, command in commands:
        request = {
            "command": command,
            "request_id": request_id,
        }

        stream.write(json.dumps(request).encode() + b"\n")
        stream.flush()

        while True:
            line = stream.readline()

            if not line:
                raise RuntimeError("mpv closed IPC connection")

            response = json.loads(line)

            if response.get("request_id") != request_id:
                continue

            if response.get("error") != "success":
                raise RuntimeError(response)

            if request_id == 1:
                if expected_version not in response.get("data", ""):
                    raise RuntimeError(response)

            if request_id == 4:
                if response.get("data") is not True:
                    raise RuntimeError(response)

            break
PY

    wait "$MPV_PID"
    MPV_PID=""
}

main() {
    prepare_sources
    build_runtime
    assemble_dist
    verify_ffmpeg_contract

    if [ -z "$BUILDER_PLATFORM" ]; then
        verify_runtime
        verify_media
        verify_portability
        verify_https
        verify_ipc
    else
        printf \
            'Skipping host runtime checks for cross-platform build: %s\n' \
            "$BUILDER_PLATFORM"
    fi

    printf '\nLinux x86_64 mpv runtime build passed.\n'
    printf 'dist: %s\n' "$DIST_DIR"
}

main "$@"
