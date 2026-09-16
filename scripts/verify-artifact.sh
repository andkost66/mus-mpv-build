#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: %s <target-id> /exact/path/to/archive.tar.zst\n' "${0##*/}" >&2
}

# Normalize architecture aliases independently of target IDs. ELF class and
# byte order are checked separately (e.g. ARM versus AArch64, or PPC64 endianness).
machine_key() {
    case "${1,,}" in
        x86_64|x86-64|amd64|'advanced micro devices x86-64') printf 'x86_64' ;;
        i386|i486|i586|i686|x86|'intel 80386') printf 'i386' ;;
        aarch64|arm64) printf 'aarch64' ;;
        arm|armhf|armel|armv7*) printf 'arm' ;;
        riscv32|riscv64|risc-v) printf 'risc-v' ;;
        ppc64|ppc64le|powerpc64|powerpc64le) printf 'powerpc64' ;;
        ppc|powerpc) printf 'powerpc' ;;
        s390x|'ibm s/390') printf 's390' ;;
        *) printf '%s' "${1,,}" ;;
    esac
}

configure_architecture() {
    TARGET_MACHINE="$(machine_key "$ARCH")"
    [[ "$(machine_key "$EXPECTED_MACHINE")" == "$TARGET_MACHINE" ]] ||
        fail "Inconsistent ARCH '$ARCH' and EXPECTED_MACHINE '$EXPECTED_MACHINE'."
    case "${ARCH,,}" in
        x86_64|x86-64|amd64|aarch64|arm64|riscv64|ppc64le|powerpc64le)
            TARGET_CLASS=ELF64; TARGET_ENDIAN='little endian' ;;
        i386|i486|i586|i686|x86|arm|armhf|armel|armv7*|riscv32)
            TARGET_CLASS=ELF32; TARGET_ENDIAN='little endian' ;;
        ppc64|powerpc64|s390x)
            TARGET_CLASS=ELF64; TARGET_ENDIAN='big endian' ;;
        ppc|powerpc)
            TARGET_CLASS=ELF32; TARGET_ENDIAN='big endian' ;;
        *) fail "Unsupported ARCH '$ARCH': add its ELF class/byte-order mapping to configure_architecture." ;;
    esac
    readonly TARGET_MACHINE TARGET_CLASS TARGET_ENDIAN
}

forbidden_runtime_name() {
    case "${1,,}" in
        yt-dlp*|yt_dlp*) return 0 ;;
        ld-linux*|ld-musl*|ld.so*|ld64.so*|ld-*.so*) return 0 ;;
        libc.so*|libm.so*|libmvec.so*|libpthread.so*|libdl.so*|librt.so*|\
        libresolv.so*|libutil.so*|libanl.so*|libnss_files.so*|libnss_dns.so*|\
        libnss_compat.so*|libnss_hesiod.so*|\
        libc-*.so*|libm-*.so*|libmvec-*.so*|libpthread-*.so*|libdl-*.so*|\
        librt-*.so*|libresolv-*.so*|libutil-*.so*|libanl-*.so*) return 0 ;;
        *) return 1 ;;
    esac
}

# Inspect data only: never invoke ldd, the interpreter, or artifact binaries.
# Cache readelf output because dependency closure revisits the same libraries.
read_elf() {
    local path="$1"
    if [[ ! ${ELF_INFO[$path]+present} ]]; then
        ELF_INFO[$path]="$(readelf --wide --file-header --program-headers \
            --dynamic --version-info -- "$path")" || fail "Cannot inspect ELF: $path"
    fi
    ELF_TEXT="${ELF_INFO[$path]}"
}

elf_matches_target() {
    local line machine='' class='' data=''
    while IFS= read -r line; do
        case "$line" in
            *'Machine:'*) machine="${line#*Machine:}"; machine="${machine#"${machine%%[![:space:]]*}"}" ;;
            *'Class:'*) class="${line##* }" ;;
            *'Data:'*) data="$line" ;;
        esac
    done <<< "$ELF_TEXT"
    ELF_DESCRIPTION="$machine, $class, ${data#*Data:}"
    [[ "$(machine_key "$machine")" == "$TARGET_MACHINE" &&
        "$class" == "$TARGET_CLASS" && "$data" == *"$TARGET_ENDIAN" ]]
}

check_glibc_versions() {
    local path="$1" versions version maximum
    # Only version *needs* are requirements; definitions are provided ABI.
    versions="$(awk '
        /^Version / { needs = ($2 == "needs"); definitions = ($2 == "definition") }
        /Name: GLIBC_/ {
            for (i = 1; i < NF; i++) if ($i == "Name:") {
                if (definitions) print "BUNDLED_GLIBC:" $(i+1)
                if (needs) print $(i+1)
            }
        }
    ' <<< "$ELF_TEXT")"
    [[ -n "$versions" ]] || return 0
    while IFS= read -r version; do
        [[ "$version" != BUNDLED_GLIBC:* ]] || fail "Bundled glibc ABI definition in ${path#"$EXTRACT_DIR/"}: ${version#*:}"
        [[ "$version" =~ ^GLIBC_[0-9]+(\.[0-9]+)+$ ]] ||
            fail "Unsupported non-numeric GLIBC requirement '$version' in ${path#"$EXTRACT_DIR/"}; cannot validate against $GLIBC_BASELINE."
    done <<< "$versions"
    maximum="$(printf '%s\n' "${versions//GLIBC_/}" | sort -V | tail -n 1)"
    if [[ -z "$MAX_GLIBC" || "$(printf '%s\n' "$MAX_GLIBC" "$maximum" | sort -V | tail -n 1)" != "$MAX_GLIBC" ]]; then
        MAX_GLIBC="$maximum"
        MAX_GLIBC_FILE="${path#"$EXTRACT_DIR/"}"
    fi
}

# Check a candidate's ELF ABI before accepting it, including host cache entries
# on multilib hosts. An incompatible artifact-local candidate must fail clearly.
try_dependency() {
    local path="$1" magic
    [[ -f "$path" ]] || return 1
    magic="$(od -An -tx1 -N4 -- "$path")" || fail "Cannot read dependency: $path"
    if [[ "$magic" != ' 7f 45 4c 46' ]]; then
        [[ "$path" != "$EXTRACT_DIR/"* ]] || fail "Artifact dependency is not ELF: $path"
        return 1
    fi
    read_elf "$path"
    if ! elf_matches_target; then
        [[ "$path" != "$EXTRACT_DIR/"* ]] || fail "Wrong architecture in $path: $ELF_DESCRIPTION (expected $ARCH)."
        return 1
    fi
    [[ "$ELF_TEXT" =~ Type:[[:space:]]+DYN[[:space:]] ]] || fail "Dependency is not an ELF shared object: $path"
    RESOLVED_DEPENDENCY="$(realpath -e -- "$path")" || fail "Cannot resolve dependency: $path"
}

resolve_dependency() {
    local owner="$1" needed="$2" candidate
    # The runtime contract is a flat lib/ directory supplied as the library
    # search path. Do not inherit LD_LIBRARY_PATH or consult out/<target>/dist.
    # Path-bearing DT_NEEDED entries are not relocatable under this contract.
    [[ "$needed" != */* ]] || fail "Non-relocatable dependency '$needed' in $owner."
    if try_dependency "$EXTRACT_DIR/lib/$needed"; then return 0; fi
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if try_dependency "$candidate"; then return 0; fi
    done <<< "${HOST_LIBRARIES[$needed]:-}"
    fail "Dependency '$needed' not found for ${owner#"$EXTRACT_DIR/"} (searched artifact lib/ and compatible host ldconfig cache entries)."
}

verify_dependencies() {
    local index path line needed interpreter dynamic_text
    local -a queue=("${ARTIFACT_ELFS[@]}")
    local -A visited=()
    for ((index = 0; index < ${#queue[@]}; index++)); do
        path="${queue[$index]}"
        [[ ! ${visited[$path]+present} ]] || continue
        visited["$path"]=1
        read_elf "$path"
        dynamic_text="$ELF_TEXT"
        while IFS= read -r line; do
            if [[ "$line" =~ \(NEEDED\).*\[([^]]+)\] ]]; then
                needed="${BASH_REMATCH[1]}"
                resolve_dependency "$path" "$needed"
                queue+=("$RESOLVED_DEPENDENCY")
            elif [[ "$line" =~ 'Requesting program interpreter: '([^]]+) ]]; then
                interpreter="${BASH_REMATCH[1]}"
                [[ "$interpreter" == /* ]] || fail "Non-absolute ELF interpreter '$interpreter' in $path."
                if ! try_dependency "$interpreter"; then
                    fail "ELF interpreter '$interpreter' not found or incompatible for ${path#"$EXTRACT_DIR/"} on this host."
                fi
                queue+=("$RESOLVED_DEPENDENCY")
            fi
        done <<< "$dynamic_text"
    done
}

run_mpv() (
    # Replace inherited library paths and prevent injected loader libraries.
    unset LD_PRELOAD LD_AUDIT
    LD_LIBRARY_PATH="$EXTRACT_DIR/lib" "$EXTRACT_DIR/bin/mpv" "$@"
)

verify_runtime() {
    local version_output audio_outputs backend
    if ! version_output="$(run_mpv --no-config --version 2>&1)"; then
        printf '%s\n' "$version_output" >&2
        fail 'Extracted mpv --version failed.'
    fi
    printf '%s\n' "$version_output"
    if ! awk -v expected="$MPV_VERSION" '
        $1 == "mpv" && ($2 == expected || $2 == "v" expected) { found = 1 }
        END { exit !found }
    ' <<< "$version_output"; then
        fail "Extracted mpv does not report expected version $MPV_VERSION."
    fi

    if ! audio_outputs="$(run_mpv --no-config --ao=help 2>&1)"; then
        printf '%s\n' "$audio_outputs" >&2
        fail 'Could not list extracted mpv audio backends.'
    fi
    for backend in pulse alsa; do
        if ! awk -v backend="$backend" '
            $1 == backend { found = 1 }
            END { exit !found }
        ' <<< "$audio_outputs"; then
            printf '%s\n' "$audio_outputs" >&2
            fail "Extracted mpv is missing the $backend audio backend."
        fi
    done
}

verify_media() {
    local fixture
    for fixture in opus.webm aac.m4a; do
        [[ -f "$REPO_ROOT/fixtures/$fixture" ]] || fail "Media fixture not found: $REPO_ROOT/fixtures/$fixture"
        if ! run_mpv --no-config --no-video --ao=null "$REPO_ROOT/fixtures/$fixture"; then
            fail "Extracted mpv media regression failed: $fixture"
        fi
    done
}

# Python owns the loopback TLS server and mpv children. Bash tracks the helper
# so EXIT/INT/TERM can request its finally blocks before deleting WORK_DIR.
verify_https_ipc() {
    python3 - "$EXTRACT_DIR" "$REPO_ROOT/fixtures" "$WORK_DIR" "$MPV_VERSION" <<'PYTHON' &
import contextlib
import functools
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time

runtime, fixtures, work = map(Path, sys.argv[1:4])
version = sys.argv[4]
os.umask(0o077)
env = os.environ.copy()
for key in list(env):
    if key in ("LD_PRELOAD", "LD_AUDIT") or key.lower().endswith("_proxy"):
        del env[key]
env["LD_LIBRARY_PATH"] = str(runtime / "lib")
mpv = [str(runtime / "bin/mpv"), "--no-config", "--no-video", "--ao=null"]


def interrupted(signum, frame):
    # Repeated signals must not interrupt child reaping / server shutdown.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise SystemExit(128 + signum)


signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)


@contextlib.contextmanager
def child(args, **kwargs):
    process = subprocess.Popen(args, **kwargs)
    try:
        yield process
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_https():
    cert, key = work / "localhost.crt", work / "localhost.key"
    # Trust only this short-lived certificate for this invocation; never change
    # system trust or disable TLS verification. The server binds only loopback.
    with child(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-days", "1", "-subj", "/CN=127.0.0.1",
                "-addext", "subjectAltName=IP:127.0.0.1",
                "-keyout", str(key), "-out", str(cert)],
               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as process:
        _, errors = process.communicate(timeout=30)
        require(process.returncode == 0, "Test certificate generation failed: " + errors.decode())
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(fixtures))
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = "https://127.0.0.1:%d/opus.webm" % server.server_port
            with child(mpv + ["--tls-verify=yes", "--tls-ca-file=" + str(cert),
                              "--network-timeout=10", url], env=env) as process:
                require(process.wait(timeout=30) == 0, "Extracted mpv HTTPS playback failed")
        finally:
            server.shutdown()
            thread.join(timeout=5)
    print("HTTPS: loopback fixture playback with certificate verification passed.", flush=True)


def verify_ipc():
    # Keep the AF_UNIX path short even when the caller has a long TMPDIR.
    # cwd is private WORK_DIR, and the socket is removed in finally and by Bash.
    ipc = work / "mpv.sock"
    try:
        with child(mpv + ["--idle=yes", "--pause=yes", "--input-terminal=no",
                          "--input-ipc-server=mpv.sock"], cwd=work, env=env) as process:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                deadline = time.monotonic() + 10
                while True:
                    require(process.poll() is None, "IPC mpv exited before opening its socket")
                    try:
                        connection.connect("mpv.sock")
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        require(time.monotonic() < deadline, "Timed out waiting for IPC socket")
                        time.sleep(0.05)
                buffer = b""
                request_id = 0
                loaded = False

                def receive(deadline):
                    nonlocal buffer, loaded
                    while b"\n" not in buffer:
                        remaining = deadline - time.monotonic()
                        require(remaining > 0, "Timed out waiting for IPC response")
                        connection.settimeout(remaining)
                        data = connection.recv(65536)
                        require(data, "IPC closed before the expected response")
                        buffer += data
                        require(len(buffer) <= 1024 * 1024, "Oversized IPC response")
                    line, buffer = buffer.split(b"\n", 1)
                    response = json.loads(line)
                    require(isinstance(response, dict), "IPC response must be a JSON object")
                    if response.get("event") == "file-loaded":
                        loaded = True
                    if response.get("event") == "end-file":
                        require(response.get("reason") != "error", "IPC media loading failed")
                    return response

                def command(*args):
                    nonlocal request_id
                    request_id += 1
                    connection.settimeout(10)
                    connection.sendall((json.dumps({"command": args, "request_id": request_id}) + "\n").encode())
                    deadline = time.monotonic() + 10
                    while True:
                        response = receive(deadline)
                        if response.get("request_id") == request_id:
                            require(response.get("error") == "success", "IPC command failed: %r: %r" % (args, response))
                            return response.get("data")

                reported = command("get_property", "mpv-version")
                require(isinstance(reported, str) and reported.split()[:2] in
                        (["mpv", version], ["mpv", "v" + version]),
                        "Unexpected IPC mpv-version: %r" % reported)
                media = str(fixtures / "opus.webm")
                command("loadfile", media, "replace")
                deadline = time.monotonic() + 10
                while not loaded:
                    receive(deadline)
                require(command("get_property", "path") == media, "IPC loaded the wrong file")
                # Round-trip both boolean values, proving a state change rather
                # than accepting the startup pause value as evidence of a set.
                for paused in (False, True):
                    command("set_property", "pause", paused)
                    require(command("get_property", "pause") is paused, "IPC pause did not change")
                command("quit")
                require(process.wait(timeout=10) == 0, "IPC quit did not exit successfully")
    finally:
        if ipc.exists():
            ipc.unlink()
    print("IPC: version, loadfile/file-loaded/path, pause round-trips and quit passed.", flush=True)


try:
    os.chdir(work)
    verify_https()
    verify_ipc()
except Exception as error:
    print("Error: HTTPS/IPC verification failed: %s" % error, file=sys.stderr)
    sys.exit(1)
PYTHON
    BACKGROUND_PID=$!
    if ! wait "$BACKGROUND_PID"; then
        fail 'Extracted artifact HTTPS/IPC regression failed.'
    fi
    BACKGROUND_PID=''
}

verify_portability() {
    local image index=0
    for image in "${PORTABILITY_IMAGE_LIST[@]}"; do
        index=$((index + 1))
        ACTIVE_CONTAINER="mus-verify-${WORK_DIR##*/}-$index"
        printf 'Portability: %s (%s), extracted artifact and both fixtures.\n' "$image" "$DOCKER_PLATFORM"
        # No pulls, installs or builds: provision these configured images before
        # verification. Only the artifact lib/ supplies bundled dependencies;
        # the base image supplies its system ABI (glibc / loader).
        timeout --signal=TERM --kill-after=5s 60s docker run --rm --pull=never \
            --name "$ACTIVE_CONTAINER" --platform "$DOCKER_PLATFORM" \
            --network=none --read-only --cap-drop=ALL \
            --security-opt=no-new-privileges \
            --mount "type=bind,src=$EXTRACT_DIR,dst=/artifact,readonly" \
            --mount "type=bind,src=$REPO_ROOT/fixtures,dst=/fixtures,readonly" \
            --env LD_LIBRARY_PATH=/artifact/lib --env LD_PRELOAD= --env LD_AUDIT= \
            --entrypoint /bin/sh "$image" -ec '
                for fixture in opus.webm aac.m4a; do
                    /artifact/bin/mpv --no-config --no-video --ao=null "/fixtures/$fixture"
                done
            ' &
        BACKGROUND_PID=$!
        if ! wait "$BACKGROUND_PID"; then
            fail "Extracted artifact portability regression failed: $image"
        fi
        BACKGROUND_PID=''
        ACTIVE_CONTAINER=''
    done
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
export LC_ALL=C
for tool in dirname cat sha256sum mktemp rm mkdir tar zstd find realpath od readelf awk sort tail python3 openssl docker timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done
# ldconfig often lives outside an unprivileged user's PATH. -p only reads cache.
LDCONFIG="$(command -v ldconfig || true)"
if [[ -z "$LDCONFIG" ]]; then
    for candidate in /sbin/ldconfig /usr/sbin/ldconfig; do
        if [[ -x "$candidate" ]]; then LDCONFIG="$candidate"; break; fi
    done
fi
[[ -n "$LDCONFIG" ]] || fail 'Required tool not found: ldconfig (static host dependency lookup).'
readonly LDCONFIG
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly REPO_ROOT
readonly TARGET_CONFIG="$REPO_ROOT/targets/$REQUESTED_TARGET/target.env"

[[ -f "$TARGET_CONFIG" ]] || fail "Unknown target '$REQUESTED_TARGET': config file not found: $TARGET_CONFIG"

# Require values from the trusted repository config, not inherited environment.
unset TARGET_ID ARCH EXPECTED_MACHINE GLIBC_BASELINE SOURCE_ENV PORTABILITY_IMAGES DOCKER_PLATFORM
source "$TARGET_CONFIG" >&2 || fail "Could not load target config: $TARGET_CONFIG"
for variable in TARGET_ID ARCH EXPECTED_MACHINE GLIBC_BASELINE SOURCE_ENV PORTABILITY_IMAGES DOCKER_PLATFORM; do
    [[ -n ${!variable:-} ]] || fail "$TARGET_CONFIG must define a non-empty $variable."
done
[[ "$TARGET_ID" == "$REQUESTED_TARGET" ]] || fail "Config TARGET_ID '$TARGET_ID' does not match requested target '$REQUESTED_TARGET'."
[[ "$GLIBC_BASELINE" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "Invalid GLIBC_BASELINE '$GLIBC_BASELINE': expected a dotted numeric version."
readonly TARGET_ID ARCH EXPECTED_MACHINE GLIBC_BASELINE SOURCE_ENV PORTABILITY_IMAGES DOCKER_PLATFORM
# Split whitespace without pathname expansion, including multiline lists.
IFS=$' \t\n' read -r -a PORTABILITY_IMAGE_LIST <<< "${PORTABILITY_IMAGES//$'\n'/ }"
[[ ${#PORTABILITY_IMAGE_LIST[@]} -gt 0 ]] || fail "$TARGET_CONFIG must list at least one PORTABILITY_IMAGES entry."
readonly -a PORTABILITY_IMAGE_LIST
configure_architecture

case "/$SOURCE_ENV/" in
    //*|*/../*)
        fail "SOURCE_ENV must be repository-relative without '..' components: $SOURCE_ENV"
        ;;
esac
[[ -f "$REPO_ROOT/$SOURCE_ENV" ]] || fail "SOURCE_ENV file not found: $REPO_ROOT/$SOURCE_ENV"
SOURCE_CONFIG="$(realpath -e -- "$REPO_ROOT/$SOURCE_ENV")" || fail "Cannot resolve SOURCE_ENV: $SOURCE_ENV"
readonly SOURCE_CONFIG
[[ "$SOURCE_CONFIG" == "$REPO_ROOT/"* ]] || fail 'SOURCE_ENV must resolve inside the repository.'
unset MPV_VERSION
source "$SOURCE_CONFIG" >&2 || fail "Could not load source contract: $SOURCE_CONFIG"
[[ ${MPV_VERSION:-} =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "$SOURCE_ENV must define a non-empty, filename-safe MPV_VERSION."
readonly MPV_VERSION

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
BACKGROUND_PID=''
ACTIVE_CONTAINER=''
cleanup() {
    local status=$?
    trap '' INT TERM
    if [[ -n "$BACKGROUND_PID" ]]; then
        kill -TERM "$BACKGROUND_PID" 2>/dev/null || true
        wait "$BACKGROUND_PID" 2>/dev/null || true
    fi
    if [[ -n "$ACTIVE_CONTAINER" ]]; then
        timeout --kill-after=5s 15s docker rm --force "$ACTIVE_CONTAINER" >/dev/null 2>&1 ||
            printf 'Warning: could not remove portability container %s; check Docker.\n' "$ACTIVE_CONTAINER" >&2
    fi
    rm -rf -- "$WORK_DIR"
    return "$status"
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

declare -A ELF_INFO=() HOST_LIBRARIES=()
declare -a ARTIFACT_ELFS=()
MAX_GLIBC=''
MAX_GLIBC_FILE=''

# Validate links before following any of them during dependency inspection.
find "$EXTRACT_DIR" -mindepth 1 -print0 > "$WORK_DIR/entries" || fail 'Could not enumerate extracted artifact.'
while IFS= read -r -d '' entry; do
    [[ ! "$entry" =~ [[:cntrl:]] ]] || fail "Control character in artifact path: $entry"
    if forbidden_runtime_name "${entry##*/}"; then
        fail "Forbidden bundled glibc/loader or yt-dlp entry: ${entry#"$EXTRACT_DIR/"}"
    fi
    if [[ -L "$entry" ]]; then
        resolved="$(realpath -e -- "$entry")" || fail "Dangling artifact symlink: ${entry#"$EXTRACT_DIR/"}"
        [[ "$resolved" == "$EXTRACT_DIR/"* ]] || fail "Artifact symlink escapes extraction: ${entry#"$EXTRACT_DIR/"} -> $resolved"
    elif [[ ! -f "$entry" && ! -d "$entry" ]]; then
        fail "Unsupported artifact file type: ${entry#"$EXTRACT_DIR/"}"
    fi
done < "$WORK_DIR/entries"

while IFS= read -r -d '' entry; do
    [[ -f "$entry" && ! -L "$entry" ]] || continue
    magic="$(od -An -tx1 -N4 -- "$entry")" || fail "Could not read artifact file: $entry"
    if [[ "$magic" != ' 7f 45 4c 46' ]]; then
        [[ "$entry" != "$EXTRACT_DIR/bin/mpv" ]] || fail 'bin/mpv is not ELF.'
        continue
    fi
    read_elf "$entry"
    elf_matches_target || fail "Wrong ELF architecture in ${entry#"$EXTRACT_DIR/"}: $ELF_DESCRIPTION (expected $ARCH / $EXPECTED_MACHINE, $TARGET_CLASS, $TARGET_ENDIAN)."
    if [[ "$entry" == "$EXTRACT_DIR/bin/mpv" ]]; then
        [[ "$ELF_TEXT" =~ Type:[[:space:]]+(EXEC|DYN)[[:space:]] &&
            "$ELF_TEXT" =~ 'Entry point address:'[[:space:]]+0x[0-9a-fA-F]*[1-9a-fA-F] &&
            "$ELF_TEXT" =~ [[:space:]]LOAD[[:space:]] ]] || fail 'bin/mpv is not an ELF executable with a nonzero entry point and loadable segments.'
        if [[ "$ELF_TEXT" =~ Type:[[:space:]]+DYN[[:space:]] ]]; then
            [[ "$ELF_TEXT" == *'Requesting program interpreter:'* || "$ELF_TEXT" =~ \(FLAGS_1\).*PIE ]] ||
                fail 'bin/mpv is an ELF shared object, not a PIE executable.'
        fi
    else
        [[ "$ELF_TEXT" =~ Type:[[:space:]]+DYN[[:space:]] ]] || fail "Artifact library is not an ELF shared object: ${entry#"$EXTRACT_DIR/"}"
    fi
    while IFS= read -r line; do
        if [[ "$line" =~ \(SONAME\).*\[([^]]+)\] ]]; then
            soname="${BASH_REMATCH[1]}"
            if forbidden_runtime_name "$soname"; then
                fail "Forbidden bundled SONAME '$soname' in ${entry#"$EXTRACT_DIR/"}."
            fi
        fi
    done <<< "$ELF_TEXT"
    check_glibc_versions "$entry"
    ARTIFACT_ELFS+=("$entry")
done < "$WORK_DIR/entries"

if [[ -n "$MAX_GLIBC" && "$(printf '%s\n' "$MAX_GLIBC" "$GLIBC_BASELINE" | sort -V | tail -n 1)" != "$GLIBC_BASELINE" ]]; then
    fail "$MAX_GLIBC_FILE requires GLIBC_$MAX_GLIBC, above configured GLIBC_BASELINE $GLIBC_BASELINE."
fi

host_cache="$("$LDCONFIG" -p)" || fail 'Could not read host ldconfig cache.'
while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+([^[:space:]]+)[[:space:]].*\ =\>\ (/.+)$ ]]; then
        name="${BASH_REMATCH[1]}"
        HOST_LIBRARIES["$name"]+="${BASH_REMATCH[2]}"$'\n'
    fi
done <<< "$host_cache"
verify_dependencies
verify_runtime
verify_media
verify_https_ipc
verify_portability

printf 'Day 11 verification passed for %s (including Day 8 archive safety and structure and Day 9 ELF checks).\nArchive: %s\n' "$TARGET_ID" "$ARCHIVE_PATH"
printf 'ELF: %s; %s artifact files checked; dependencies resolved statically (artifact lib/ + host cache).\n' "$ARCH" "${#ARTIFACT_ELFS[@]}"
printf 'Maximum required GLIBC: %s; configured baseline: %s.\n' "${MAX_GLIBC:-none}" "$GLIBC_BASELINE"
printf 'Runtime: mpv %s; pulse and alsa backends present; opus.webm and aac.m4a passed.\n' "$MPV_VERSION"
printf 'Day 11: local HTTPS and JSON IPC passed; both fixtures passed in: %s.\n' "$PORTABILITY_IMAGES"
