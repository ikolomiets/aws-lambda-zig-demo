#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-packaging-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP_DIR"' EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# Run the deployment entry point in an isolated checkout so its artifact cleanup
# and working-directory changes cannot affect real build outputs.
mkdir -p "$TEST_TMP_DIR/repo" "$TEST_TMP_DIR/zig/lib/std/Io/net" \
    "$TEST_TMP_DIR/aws-lambda-zig/src"
cp "$REPOSITORY_ROOT/deploy.sh" "$TEST_TMP_DIR/repo/"
touch "$TEST_TMP_DIR/zig/lib/std/Io/net/HostName.zig" \
    "$TEST_TMP_DIR/aws-lambda-zig/build.zig.zon" \
    "$TEST_TMP_DIR/aws-lambda-zig/src/root.zig"

cat >"$TEST_TMP_DIR/driver.sh" <<'BASH'
set -euo pipefail
source "$1/repo/deploy.sh"
MOCK_LOG="$1/calls.log"
MOCK_PACKAGE_STATUS="$2"
shift 2
PASETO_PUBLIC_KEY=mock-public-key
LOCAL_AWS_LAMBDA_ROOT=../aws-lambda-zig

need_command() { printf 'need:%s\n' "$1" >>"$MOCK_LOG"; }
prepare_aws_sso_session() { :; }
ensure_stack_not_in_progress() { :; }
require_seat_development_baseline() { :; }
validate_existing_intake_name() { :; }
invoke_deployment_controller() { :; }
aws() { printf 'unexpected AWS call\n' >&2; exit 90; }
zip() { printf 'unexpected shell packaging\n' >&2; exit 91; }
zig() {
    [ "$1" != version ] || { printf '0.16.0\n'; return; }
    printf 'zig:%s\n' "$*" >>"$MOCK_LOG"
    if [ "$2" = package ]; then
        [ "$MOCK_PACKAGE_STATUS" -eq 0 ] || return "$MOCK_PACKAGE_STATUS"
        mkdir -p zig-out/packages
        for archive in intake-lambda query-lambda tiger-beetle-processor \
            tiger-beetle-completion-processor seat-reservation-processor \
            seat-reservation-completion-processor
        do
            printf 'mock archive\n' >"zig-out/packages/$archive.zip"
        done
    fi
}
file() {
    printf 'file:%s\n' "$*" >>"$MOCK_LOG"
    case "$1" in
        zig-out/bin/tiger_beetle_processor/bootstrap) linkage='dynamically linked' ;;
        *) linkage='statically linked' ;;
    esac
    printf '%s: ELF 64-bit LSB executable, ARM aarch64, %s, stripped\n' "$1" "$linkage"
}
unzip() {
    printf 'unzip:%s\n' "$*" >>"$MOCK_LOG"
    printf 'bootstrap\n'
}
sam() {
    printf 'sam:%s\n' "$*" >>"$MOCK_LOG"
    # Successful sync is the boundary of this packaging test. Post-sync cloud
    # summaries are covered separately and must not contact AWS here.
    [ "$1" != sync ] || exit 0
}
deploy_stack_and_resolve_controller_outputs() {
    printf 'deploy\n' >>"$MOCK_LOG"
    exit 0
}
run_deployment "$@"
BASH

for mode in full dev; do
    mode_args=(--no-url-check)
    cache_suffix=deploy
    if [ "$mode" = dev ]; then
        mode_args+=(--dev)
        cache_suffix=dev
    fi
    for dry_run in yes no; do
        dry_args=(--use-local-libs)
        [ "$dry_run" != yes ] || dry_args+=(--dry-run)
        for package_status in 0 42; do
            : >"$TEST_TMP_DIR/calls.log"
            status=0
            bash "$TEST_TMP_DIR/driver.sh" "$TEST_TMP_DIR" "$package_status" \
                "${mode_args[@]}" "${dry_args[@]}" \
                >"$TEST_TMP_DIR/output.log" 2>&1 || status=$?
            [ "$status" -eq "$package_status" ] || {
                cat "$TEST_TMP_DIR/output.log" >&2
                fail_test "$mode dry=$dry_run: expected $package_status, received $status"
            }
            calls="$(cat "$TEST_TMP_DIR/calls.log")"
            expected="zig:build package --cache-dir .zig-cache-$cache_suffix --global-cache-dir .zig-global-cache-$cache_suffix --fork=../aws-lambda-zig --release -Darch=arm"
            [[ "$calls" == *"$expected"* ]] || fail_test "packaging options changed: $calls"
            [[ "$calls" != *'need:zip'* ]] || fail_test "zip is still required"
            if [ "$package_status" -ne 0 ]; then
                if grep -Eq '^(file:|unzip:|sam:|deploy$)' "$TEST_TMP_DIR/calls.log"; then
                    fail_test "packaging failure did not stop validation/deployment: $calls"
                fi
                continue
            fi
            [ "$(grep -c '^unzip:-Z1 zig-out/packages/.*\.zip$' "$TEST_TMP_DIR/calls.log")" -eq 6 ] ||
                fail_test "deployment did not validate six packages"
            if [ "$mode" = dev ]; then
                [[ "$calls" != *'zig:build test '* && "$calls" != *'sam:validate '* ]] ||
                    fail_test "development mode ran full checks"
            else
                [[ "$calls" == *'zig:build test '* && "$calls" == *'sam:validate --lint '* ]] ||
                    fail_test "full mode skipped required checks"
            fi
            if [ "$dry_run" = yes ]; then
                [[ "$calls" != *'sam:sync '* && "$calls" != *$'\ndeploy' ]] ||
                    fail_test "dry run attempted deployment"
            elif [ "$mode" = dev ]; then
                [[ "$calls" == *'sam:sync '* ]] || fail_test "development mode skipped sync"
            else
                [[ "$calls" == *$'\ndeploy' ]] || fail_test "full mode skipped deployment"
            fi
        done
    done
done

printf 'PASS: deployment packaging regression tests\n'
