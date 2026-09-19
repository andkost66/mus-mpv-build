FROM debian:buster-slim@sha256:32220ea48be72979c9f0810d69f3de9145c9584c2ee966c6ec26edbcf4640c0b
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

# These main/updates snapshots have no Valid-Until field. Only security is expired.
# Keep APT signature verification enabled; HTTP bootstraps ca-certificates.
RUN printf '%s\n' \
        'deb http://snapshot.debian.org/archive/debian/20240211T000000Z/ buster main' \
        'deb http://snapshot.debian.org/archive/debian/20240211T000000Z/ buster-updates main' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20240701T000000Z/ buster/updates main' \
        > /etc/apt/sources.list \
    && apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
        build-essential \
        git \
        ca-certificates \
        python3 \
        python3-pip \
        python3-venv \
        ninja-build \
        pkg-config \
        cmake \
        autoconf \
        automake \
        libtool \
        nasm \
        libfreetype6-dev \
        libfribidi-dev \
        libharfbuzz-dev \
        libgnutls28-dev \
        libasound2-dev \
        libpulse-dev \
        curl \
        xz-utils \
        zlib1g-dev \
        libssl-dev \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Build against Buster's libc, preserving Debian's /usr/bin/python3.
# ensurepip uses the bootstrap wheels bundled in the verified CPython source.
RUN set -eu; \
    build_dir="$(mktemp -d)"; \
    cd "$build_dir"; \
    curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
        --output Python-3.11.14.tar.xz \
        https://www.python.org/ftp/python/3.11.14/Python-3.11.14.tar.xz; \
    printf '%s  %s\n' \
        '8d3ed8ec5c88c1c95f5e558612a725450d2452813ddad5e58fdb1a53b1209b78' \
        'Python-3.11.14.tar.xz' | sha256sum --check --strict -; \
    tar -xJf Python-3.11.14.tar.xz; \
    cd Python-3.11.14; \
    ./configure --prefix=/usr/local --with-ensurepip=install; \
    make -j"$(nproc)"; \
    make altinstall; \
    ln -s python3.11 /usr/local/bin/python3; \
    cd /; \
    rm -rf "$build_dir"

RUN set -eu; \
    download_dir="$(mktemp -d)"; \
    cd "$download_dir"; \
    curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
        --output meson-1.11.2-py3-none-any.whl \
        https://files.pythonhosted.org/packages/1d/c5/680527bdddf039807f22041882678b7f21d3380b4cdbc46abf2f24e2db6c/meson-1.11.2-py3-none-any.whl; \
    printf '%s  %s\n' \
        '7e4f6e83fec83e3eaac928e058b073c7557b282c35b6a2024cea143a39926a39' \
        'meson-1.11.2-py3-none-any.whl' | sha256sum --check --strict -; \
    python3 -m pip install --no-index --no-deps --no-cache-dir \
        --disable-pip-version-check ./meson-1.11.2-py3-none-any.whl; \
    cd /; \
    rm -rf "$download_dir"

# Match the login-shell invocation used by build-target.sh.
RUN sh -lc 'set -eu; \
    . /etc/os-release; \
    test "$VERSION_ID" = 10; \
    test "$(dpkg --print-architecture)" = amd64; \
    test "$(uname -m)" = x86_64; \
    test "$(getconf GNU_LIBC_VERSION)" = "glibc 2.28"; \
    test "$(command -v python3)" = /usr/local/bin/python3; \
    test "$(readlink -f "$(command -v python3)")" = /usr/local/bin/python3.11; \
    python3 -c "import sys, ssl, zlib, ctypes; assert sys.version_info[:3] == (3, 11, 14)"; \
    test "$(command -v meson)" = /usr/local/bin/meson; \
    test "$(meson --version)" = 1.11.2'
