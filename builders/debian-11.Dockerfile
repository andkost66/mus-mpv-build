FROM debian:11
ENV DEBIAN_FRONTEND=noninteractive

RUN printf '%s\n' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260824T000000Z bullseye main' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260824T000000Z bullseye-security main' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260824T000000Z bullseye-updates main' \
        > /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
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
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir 'meson==1.11.2'
