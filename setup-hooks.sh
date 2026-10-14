#!/usr/bin/env bash
set -euo pipefail

setup_error() {
    printf 'Hook setup error: %s\n' "$*" >&2
    exit 2
}

[[ $# -eq 0 ]] || setup_error 'setup-hooks.sh accepts no arguments.'
command -v git >/dev/null || setup_error 'Git is required.'
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ "$(git rev-parse --show-toplevel)" == "$(pwd -P)" ]] ||
    setup_error 'Run setup from this repository checkout.'
[[ -x .githooks/pre-commit && -x check.sh ]] ||
    setup_error 'The tracked pre-commit hook and check.sh must be executable.'

if configured="$(git config --get-all core.hooksPath)"; then
    [[ "$configured" == '.githooks' ]] ||
        setup_error "core.hooksPath is already configured as '$configured'; preserve or integrate it manually."
else
    # Git uses this directory only when core.hooksPath is unset. Samples are
    # inactive; any other entry may belong to an existing local workflow.
    hooks_directory="$(git rev-parse --git-path hooks)"
    shopt -s nullglob
    for hook in "$hooks_directory"/* "$hooks_directory"/.[!.]* "$hooks_directory"/..?*; do
        [[ "$hook" == *.sample ]] && continue
        setup_error "Existing hook entry '$hook'; preserve or integrate it manually."
    done
fi

git config --local core.hooksPath .githooks
[[ "$(git config --get core.hooksPath)" == '.githooks' ]] ||
    setup_error 'The effective core.hooksPath is not .githooks.'
printf 'Local hooks configured: core.hooksPath=.githooks (pre-commit runs ./check.sh).\n'
