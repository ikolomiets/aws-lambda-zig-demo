#!/usr/bin/env bash
set -euo pipefail

setup_error() {
    printf 'Local check setup error: %s\n' "$*" >&2
    exit 2
}

[[ $# -eq 0 ]] || setup_error 'check.sh accepts no arguments.'

for tool in bash jq python3 zig uname dirname find; do
    command -v "$tool" >/dev/null || setup_error "Install $tool before checking."
done
cd "$(dirname "${BASH_SOURCE[0]}")"
bash_path="$(command -v bash)"
bash --version >/dev/null ||
    setup_error "Bash at $bash_path is unavailable (runner Bash $BASH_VERSION)."
jq --version >/dev/null || setup_error 'jq is unavailable.'
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' ||
    setup_error 'Python 3.9 or newer is required.'
[[ "$(zig version)" == '0.16.0' ]] || setup_error 'Zig 0.16.0 is required.'

case "$(uname -s):$(uname -m)" in
    Darwin:arm64) ;;
    Linux:aarch64|Linux:arm64)
        command -v getconf >/dev/null || setup_error 'getconf is required to identify glibc.'
        glibc_version="$(getconf GNU_LIBC_VERSION)" || setup_error 'Cannot identify glibc.'
        [[ "$glibc_version" == glibc\ * ]] ||
            setup_error 'ARM64 Linux must use glibc.'
        python3 -c 'import sys; sys.exit(tuple(map(int, sys.argv[1].split("."))) < (2, 27))' \
            "${glibc_version#glibc }" || setup_error 'glibc 2.27 or newer is required.'
        ;;
    *) setup_error 'Use an ARM64 macOS or ARM64 glibc Linux host.' ;;
esac

# --system uses provisioned package sources and disables Zig package fetching.
packages="${CHECK_ZIG_PACKAGE_DIR:-zig-pkg}"
[[ -d "$packages" ]] || setup_error "Provision pinned packages in $packages before checking."
zig build --system "$packages" --help >/dev/null ||
    setup_error 'The build graph must configure with provisioned pinned packages (see README).'

zig build fmt-check --system "$packages"
shopt -s nullglob
for script in ./*.sh .githooks/*; do
    bash -n "$script"
done
find tests -type f -name '*.sh' -print0 |
    while IFS= read -r -d '' script; do
        bash -n "$script"
    done
python3 check_docs.py
python3 tracker.py validate
zig build test --system "$packages"
printf 'Local offline checks passed.\n'
