# mus-mpv-build

## Headless audio playback

- Linux x86_64.
- headless audio playback.
- PulseAudio and ALSA.
- WebM/Opus and M4A/AAC.
- HTTPS.
- JSON IPC.

This may be useful for developers who need a small, portable mpv build for headless audio playback without relying on a system-installed mpv.

Tested on:
- Debian 11.
- Ubuntu 20.04.
- Ubuntu 22.04.

Requires glibc 2.31 or newer (works out of the box on Debian 11+, Ubuntu 20.04+).

## License

The build scripts, CI configuration, Dockerfile, and documentation authored
for this repository are available under the [MIT License](LICENSE).

Release artifacts contain third-party software under their respective
licenses. In particular, the current mpv executable is distributed under
GPL-2.0-or-later. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for
component revisions and license information.
