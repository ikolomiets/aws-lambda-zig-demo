#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/processor-interface-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AWS_CALLS"
exit 99
MOCK
chmod +x "$TEST_DIR/bin/aws"
export PATH="$TEST_DIR/bin:$PATH" AWS_CALLS="$TEST_DIR/aws-calls"
: >"$AWS_CALLS"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail_test "missing: $2" ;; esac; }

for helper in deploy.sh wireguard-gateway-setup.sh; do
    for processor in execution completion; do
        replacement=tiger-beetle-processor
        retired_env=EXECUTION_FUNCTION_NAME
        replacement_env=TIGER_BEETLE_PROCESSOR_NAME
        if [ "$processor" = completion ]; then
            replacement=tiger-beetle-completion-processor
            retired_env=COMPLETION_FUNCTION_NAME
            replacement_env=TIGER_BEETLE_COMPLETION_PROCESSOR_NAME
        fi
        for form in separate equals; do
            args=("--$processor-function-name" old-name)
            if [ "$form" = equals ]; then args=("--$processor-function-name=old-name"); fi
            if output="$(bash "$REPOSITORY_ROOT/$helper" "${args[@]}" 2>&1)"; then
                fail_test "$helper accepted a retired flag"
            fi
            contains "$output" "use --$replacement-name"
        done
        for value in old-name ''; do
            if output="$(env "$retired_env=$value" bash "$REPOSITORY_ROOT/$helper" --dry-run 2>&1)"; then
                fail_test "$helper accepted retired environment override"
            fi
            contains "$output" "use $replacement_env"
        done
    done
    if output="$(env COMPLETION_PROCESSOR_NAME=old-name bash "$REPOSITORY_ROOT/$helper" --dry-run 2>&1)"; then
        fail_test "$helper accepted the former completion processor environment name"
    fi
    contains "$output" 'use TIGER_BEETLE_COMPLETION_PROCESSOR_NAME'
    if output="$(bash "$REPOSITORY_ROOT/$helper" --completion-processor-name old-name 2>&1)"; then
        fail_test "$helper accepted the former completion processor flag"
    fi
    contains "$output" 'use --tiger-beetle-completion-processor-name'
    output="$(bash "$REPOSITORY_ROOT/$helper" --help)"
    contains "$output" '--tiger-beetle-processor-name'
    contains "$output" '--tiger-beetle-completion-processor-name'
done
for selector in execution completion; do
    if output="$(bash "$REPOSITORY_ROOT/lambda_logs.sh" "$selector" 2>&1)"; then
        fail_test "retired log selector accepted"
    fi
    contains "$output" 'is retired; use'
done
[ ! -s "$AWS_CALLS" ] || fail_test "retired interfaces contacted AWS"

# Exercise both shared-parser forms as forwarded by the WireGuard entrypoint.
source "$REPOSITORY_ROOT/wireguard-gateway-setup.sh"
parse_wireguard_options --tiger-beetle-processor-name custom-tb --tiger-beetle-completion-processor-name custom-completion
parse_deployment_options "${COMMON_DEPLOYMENT_ARGS[@]}"
[ "$TIGER_BEETLE_PROCESSOR_NAME" = custom-tb ] && [ "$TIGER_BEETLE_COMPLETION_PROCESSOR_NAME" = custom-completion ] ||
    fail_test "WireGuard did not forward separate processor arguments"
parse_wireguard_options --tiger-beetle-processor-name=equal-tb --tiger-beetle-completion-processor-name=equal-completion
parse_deployment_options "${COMMON_DEPLOYMENT_ARGS[@]}"
[ "$TIGER_BEETLE_PROCESSOR_NAME" = equal-tb ] && [ "$TIGER_BEETLE_COMPLETION_PROCESSOR_NAME" = equal-completion ] ||
    fail_test "WireGuard did not forward equals processor arguments"

output="$(env TIGER_BEETLE_PROCESSOR_NAME=env-tb TIGER_BEETLE_COMPLETION_PROCESSOR_NAME=env-completion \
    bash -c 'source "$1/deploy.sh"; build_sam_parameter_overrides; printf "%s\n" "${SAM_PARAMETER_OVERRIDES[@]}"' \
    bash "$REPOSITORY_ROOT")"
contains "$output" 'TigerBeetleProcessorName=env-tb'
contains "$output" 'TigerBeetleCompletionProcessorName=env-completion'

# A deliberately failing lookup checks the selected output key without writing
# any downloaded logs or issuing a CloudWatch request.
for selector in tiger-beetle-processor tiger-beetle-completion-processor; do
    : >"$AWS_CALLS"
    if output="$(bash "$REPOSITORY_ROOT/lambda_logs.sh" "$selector" 2>&1)"; then
        fail_test "failed stack lookup unexpectedly succeeded"
    fi
    key=TigerBeetleProcessorName
    if [ "$selector" = tiger-beetle-completion-processor ]; then key=TigerBeetleCompletionProcessorName; fi
    contains "$(cat "$AWS_CALLS")" "OutputKey=='$key'"
done
printf 'PASS: processor interface regression tests\n'
