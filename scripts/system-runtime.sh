#!/usr/bin/env bash
set -euo pipefail

# Shared OS ABI contract. These components are never bundled. All other
# DT_NEEDED libraries must be supplied by the artifact, not the verifier host.

system_loader_name() {
    case "$1" in
        ld-linux-x86-64.so.2|ld-linux.so.2|ld-linux.so.3|ld-linux-armhf.so.3|\
        ld-linux-aarch64.so.1|ld-linux-riscv64-lp64d.so.1|ld64.so.1|ld64.so.2)
            return 0 ;;
        *) return 1 ;;
    esac
}

system_runtime_name() {
    system_loader_name "$1" && return 0
    case "$1" in
        libc.so.6|libm.so.6|libmvec.so.1|libpthread.so.0|libdl.so.2|librt.so.1|\
        libresolv.so.2|libutil.so.1|libanl.so.1|libnsl.so.1|\
        libnss_files.so.2|libnss_dns.so.2|libnss_compat.so.2|libnss_hesiod.so.2)
            return 0 ;;
        *) return 1 ;;
    esac
}
