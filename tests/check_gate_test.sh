#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/check-gate-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
original_path="$PATH"
checks=0

fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
new_fixture() {
    project="$(mktemp -d "$test_root/project.XXXXXX")"
    cp "$ROOT/check.sh" "$project/check.sh"
    mkdir "$project/tests" "$project/scripts" "$project/bin" "$project/arguments"
    cat >"$project/bin/zig" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = version ]; then
    printf '%s\n' "$TEST_ZIG_VERSION"
    exit 0
fi
printf '%s\n' "$2" >>"$TEST_ZIG_CALLS"
printf '%s\0' "$@" >"$TEST_ZIG_ARGS_DIR/$2"
if [ "$2" = "$TEST_FAIL_STEP" ]; then exit 42; fi
MOCK
    chmod +x "$project/bin/zig"
    export PATH="$project/bin:$original_path"
    export TEST_ZIG_CALLS="$project/calls" TEST_ZIG_ARGS_DIR="$project/arguments"
    export TEST_ZIG_VERSION=0.17.1 TEST_FAIL_STEP= ZIG_PACKAGE_DIR=zig-pkg
    : >"$TEST_ZIG_CALLS"
}
run_gate() {
    gate_status=0
    (cd "$project" && bash check.sh "$@") >"$test_root/output" 2>&1 || gate_status=$?
    checks=$((checks + 1))
}
assert_calls() {
    [ "$(cat "$TEST_ZIG_CALLS")" = "$1" ] || fail_test 'gate ran unexpected build phases'
}
assert_arguments() {
    local file="$1" argument expected index=0
    local arguments=()
    shift
    while IFS= read -r -d '' argument; do
        arguments+=("$argument")
    done <"$file"
    [ "${#arguments[@]}" -eq "$#" ] || fail_test 'gate changed the argument count'
    for expected in "$@"; do
        [ "${arguments[$index]}" = "$expected" ] || fail_test 'gate split or changed an argument'
        index=$((index + 1))
    done
}

new_fixture
export ZIG_PACKAGE_DIR='packages with spaces'
run_gate
[ "$gate_status" -eq 0 ] || fail_test 'offline gate failed'
assert_calls $'fmt-check\ntest'
assert_arguments "$TEST_ZIG_ARGS_DIR/fmt-check" build fmt-check --system 'packages with spaces'
assert_arguments "$TEST_ZIG_ARGS_DIR/test" build test --system 'packages with spaces' --summary all

new_fixture
export TEST_FAIL_STEP=fmt-check
run_gate --runtime
[ "$gate_status" -eq 42 ] || fail_test 'gate lost the compiler exit status during output capture'
assert_calls fmt-check

new_fixture
mkdir "$project/tests/nested"
printf 'if then\n' >"$project/tests/nested/invalid.sh"
run_gate
[ "$gate_status" -ne 0 ] || fail_test 'gate accepted invalid recursive shell syntax'
assert_calls fmt-check

new_fixture
printf 'if then\n' >"$project/scripts/invalid.sh"
run_gate
[ "$gate_status" -ne 0 ] || fail_test 'gate accepted invalid tool syntax'
assert_calls fmt-check

new_fixture
run_gate --runtime
[ "$gate_status" -eq 0 ] || fail_test 'runtime gate failed'
assert_calls $'fmt-check\ntest\ntest-runtime'
assert_arguments "$TEST_ZIG_ARGS_DIR/test-runtime" build test-runtime --system zig-pkg --summary all

new_fixture
rmdir "$project/tests"
run_gate
[ "$gate_status" -ne 0 ] || fail_test 'gate ignored failed script discovery'
assert_calls fmt-check

new_fixture
export TEST_ZIG_VERSION=0.16.0
run_gate
[ "$gate_status" -ne 0 ] || fail_test 'gate accepted an unsupported compiler'
assert_calls ''
printf 'Validation gate tests passed (%s checks).\n' "$checks"
