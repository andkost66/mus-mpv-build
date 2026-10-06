# mus-mpv-build

Headless mpv runtime for PulseAudio and ALSA, WebM/Opus and M4A/AAC,
HTTPS playback and JSON IPC. The runtime contains only `bin/mpv` and shared
libraries in `lib/`. It does not include yt-dlp, glibc or a dynamic loader.

## Targets

| Target | Builder | Configured glibc ABI ceiling | Portability environments |
| --- | --- | --- | --- |
| `linux-x86_64` | Debian 11 x86_64 | 2.31 | Debian 11 slim, Ubuntu 20.04, Ubuntu 22.04 |
| `linux-x86_64-glibc-2.28` | Debian 10 x86_64 | 2.28 | Debian 10/11/12 slim, Ubuntu 20.04, Ubuntu 22.04 |

Both targets use the same pinned upstream revisions and headless audio build
profile. The target platform is Linux x86_64 (`linux/amd64`). Each `target.env`
selects the builder and configures `GLIBC_BASELINE`; the builder supplies the
corresponding toolchain and libc. Runtime compatibility is checked by
running both fixtures in each listed container environment. Containers share
the host kernel: these checks do not test every kernel, CPU or audio device.
Debian 10 compatibility does not imply security support for Debian 10.

## Build and verify locally

Use Linux x86_64 with Git, Bash, Docker, Python 3.8+, OpenSSL, GNU coreutils,
GNU tar, binutils and zstd. Provision the configured portability images before
building; the verifier never downloads images or installs runtime packages.
For either target, run from the repository root:

```bash
target=linux-x86_64 # or linux-x86_64-glibc-2.28
source "targets/$target/target.env"
for image in $PORTABILITY_IMAGES; do
    docker pull --platform "$DOCKER_PLATFORM" "$image"
done
./scripts/build-package-verify.sh "$target"
```

The direct pipeline commands are:

```bash
./scripts/build-package-verify.sh linux-x86_64
./scripts/build-package-verify.sh linux-x86_64-glibc-2.28
```

Each pipeline builds, packages and verifies its own runtime. Outputs are
`out/<target>/dist/` and `out/<target>/artifacts/`. Build scratch directories
are temporary and removed on exit.

Archives use these names, with the first 12 commit digits:

```text
mpv-0.41.0-linux-x86_64-rev.<short-sha>.tar.zst
mpv-0.41.0-linux-x86_64-glibc-2.28-rev.<short-sha>.tar.zst
```

Each archive has a matching `.sha256` file. Fixtures, sources and logs are not
packaged.

Verify any existing archive using its exact path:

```bash
./scripts/verify-artifact.sh linux-x86_64 /absolute/path/to/archive.tar.zst
```

Use the matching target ID for the glibc 2.28 archive. The verifier checks
checksum, archive paths and layout, every ELF file, the glibc ceiling,
bundled ELF `DT_NEEDED` dependency closure and bundled-library symbol versions.
Non-system `DT_NEEDED` dependencies must be in artifact `lib/`; only the
explicit OS ABI list in `scripts/system-runtime.sh` may come from the system.
Runtime checks, both HTTPS fixtures, JSON IPC and all configured portability
tests are mandatory.

## Run an extracted runtime

Supply the extracted library directory when invoking mpv; extracting an
archive alone does not add `lib/` to the system loader search path:

```bash
runtime=/absolute/path/to/extracted/runtime
LD_LIBRARY_PATH="$runtime/lib" "$runtime/bin/mpv" --no-config --no-video /path/to/audio.m4a
```

A working PulseAudio service or ALSA device/configuration is still required
for real audio output. Verification uses the null audio output for media
playback and separately checks that PulseAudio and ALSA backends are present.

## CI and candidates

Each target has its own workflow, without matrix or QEMU. Publication is
restricted to pushes to `main`: the pipeline verifies the local archive,
uploads and re-downloads the exact Actions artifact, removes original outputs,
and repeats verification before creating a prerelease. A separate read-only
job downloads and verifies the published Release assets.

Candidate tags are `mpv-<version>-rev.<short-sha>` for `linux-x86_64` and
`mpv-<version>-linux-x86_64-glibc-2.28-rev.<short-sha>` for the second target.
Existing tags or releases cause failure; candidates are never overwritten and
are not promoted automatically.

Run the focused regression tests with `python3 tests/test-artifact-contract.py`.
They require an x86_64 C compiler and the verifier tools (including the Docker
CLI), but do not start containers, download images or build mpv.

## License

Repository-authored build scripts, CI configuration, Dockerfiles and
documentation are available under the [MIT License](LICENSE). Release
artifacts contain third-party software under their respective licenses;
the mpv executable is distributed under GPL-2.0-or-later. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for source and license details.
