# Third-party notices

The MIT License in [LICENSE](LICENSE) applies only to material authored for
this repository, including its build scripts, CI workflows, Dockerfile,
configuration files, and documentation, unless otherwise stated.

It does not relicense third-party software downloaded, built, linked, or
redistributed by this project. Each third-party component remains subject to
its own license terms.

## Direct build inputs

The exact revisions used by the current build are recorded in
[`linux-x86_64/source.env`](linux-x86_64/source.env).

| Component | License used by the current build | Source and license information |
| --- | --- | --- |
| mpv | GPL-2.0-or-later | [Source](https://github.com/mpv-player/mpv/tree/41f6a645068483470267271e1d09966ca3b9f413) · [Copyright and licensing](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/Copyright) |
| FFmpeg | LGPL-2.1-or-later | [Source](https://github.com/FFmpeg/FFmpeg/tree/bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa) · [License](https://github.com/FFmpeg/FFmpeg/blob/bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa/LICENSE.md) |
| libass | ISC | [Source](https://github.com/libass/libass/tree/b2fe9d8770678a7b5271387d38c20657ebf3429a) · [License](https://github.com/libass/libass/blob/b2fe9d8770678a7b5271387d38c20657ebf3429a/COPYING) |
| libplacebo | LGPL-2.1-or-later | [Source](https://github.com/haasn/libplacebo/tree/cee9b076f2c63104ccfd497fa79c39a867293ec4) · [License](https://github.com/haasn/libplacebo/blob/cee9b076f2c63104ccfd497fa79c39a867293ec4/LICENSE) |

The current mpv configuration does not disable mpv's GPL build mode, so the
distributed mpv executable is GPL-2.0-or-later. The FFmpeg configuration does
not enable FFmpeg's GPL or nonfree modes.

## Other shared libraries

Release archives may also contain dynamically linked shared libraries copied
from the Debian 11 build environment. Those libraries remain under their own
licenses. The table above covers the components built directly by this
repository and is not an exhaustive inventory of system-provided libraries.

The revision links above provide traceability, but do not replace any source
code, attribution, or license-text obligations that apply when redistributing
binary artifacts. A matching source and license manifest should accompany
future binary releases.
