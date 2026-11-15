#!/usr/bin/env bash
set -euo pipefail

runtime=0
case "${1:-}" in
    '') [ "$#" -eq 0 ] || exit 2 ;;
    --runtime) [ "$#" -eq 1 ] || exit 2; runtime=1 ;;
    -h|--help)
        printf 'Usage: ./check.sh [--runtime]\nUses provisioned ZIG_PACKAGE_DIR (default: zig-pkg).\n'
        exit 0
        ;;
    *) printf 'Usage: ./check.sh [--runtime]\n' >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")"
version="$(zig version)"
if [[ ! "$version" =~ ^0\.17\.[0-9]+$ ]]; then
    printf 'Checks require Zig 0.17.x (minimum 0.17.0).\n' >&2
    exit 1
fi
package_dir="${ZIG_PACKAGE_DIR:-zig-pkg}"

# Keep commands direct: a failed check must remain the process exit status,
# even when the caller captures output in a log.
zig build fmt-check --system "$package_dir"
for script in ./*.sh; do
    bash -n "$script"
done
shell_scripts="$(mktemp "${TMPDIR:-/tmp}/offline-shells.XXXXXX")"
trap 'rm -f "$shell_scripts"' EXIT
find tests scripts -type f -name '*.sh' -print0 > "$shell_scripts"
while IFS= read -r -d '' script; do
    bash -n "$script"
done < "$shell_scripts"
if [ -f .githooks/pre-commit ]; then
    bash -n .githooks/pre-commit
fi
zig build test --system "$package_dir" --summary all
if [ "$runtime" -eq 1 ]; then
    zig build test-runtime --system "$package_dir" --summary all
fi
