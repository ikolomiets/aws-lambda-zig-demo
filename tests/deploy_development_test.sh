#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-development-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP_DIR"' EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail_test "expected output to contain: $2" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail_test "unexpected output: $2" ;;
        *) ;;
    esac
}

# Run the real script in an isolated checkout with mocks only at command boundaries.
mkdir -p "$TEST_TMP_DIR/bin" "$TEST_TMP_DIR/zig/lib/std/Io/net"
touch "$TEST_TMP_DIR/zig/lib/std/Io/net/HostName.zig"
cat >"$TEST_TMP_DIR/bin/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
command_name="${0##*/}"
printf '%s %s\n' "$command_name" "$*" >>"$MOCK_CALL_LOG"
if [ "${MOCK_FAILURE:-}" = "$command_name:${1:-}" ]; then
    exit 42
fi
case "$command_name" in
    zig)
        case "$1" in
            version) printf '%s\n' "${MOCK_ZIG_VERSION:-0.16.0}" ;;
            build)
                for ((index=1; index<=$#; index++)); do
                    case "${!index}" in
                        --cache-dir | --global-cache-dir)
                            index=$((index + 1))
                            mkdir -p "${!index}"
                            printf 'cached\n' >"${!index}/retained"
                            ;;
                    esac
                done
                mkdir -p zig-out/bin
                cat >zig-out/bin/paseto <<'PASETO'
#!/usr/bin/env bash
printf 'paseto %s\n' "$*" >>"$MOCK_CALL_LOG"
printf 'mock-token\n'
PASETO
                chmod +x zig-out/bin/paseto
                ;;
        esac
        ;;
    file)
        if [ "${MOCK_BAD_BOOTSTRAP:-0}" -eq 1 ]; then
            printf 'invalid bootstrap\n'
            exit 0
        fi
        case "$1" in
            *tiger_beetle_processor/bootstrap) linkage='dynamically linked' ;;
            *) linkage='statically linked' ;;
        esac
        printf '%s: ELF 64-bit LSB executable, ARM aarch64, %s, stripped\n' "$1" "$linkage"
        ;;
    zip) printf 'archive\n' >"$2" ;;
    unzip) printf '%s\n' "${MOCK_ARCHIVE_CONTENTS:-bootstrap}" ;;
    sam)
        if [ "$1" = sync ] && [ "${MOCK_SAM_CONFIRMATION:-0}" -eq 1 ]; then
            read -r reply || exit 95
            [ "$reply" = Y ] || exit 96
            # Exactly one answer is supplied, so an additional prompt reaches EOF.
            if read -r reply; then
                exit 97
            fi
        fi
        ;;
    curl)
        if [ -n "${MOCK_HTTP_STATUS:-}" ]; then
            printf '%s' "$MOCK_HTTP_STATUS"
            exit 0
        fi
        case "$*" in
            *Authorization*00000000-0000-4000-8000-000000000000*) printf '404' ;;
            *'-X POST'*Authorization*query.example.invalid*) printf '405' ;;
            *'-X POST'*Authorization*intake.example.invalid*) printf '400' ;;
            *Authorization*) printf '405' ;;
            *) printf '401' ;;
        esac
        ;;
    aws)
        query=''
        logical_id=''
        arguments="$*"
        service="$1"
        operation="$2"
        shift 2
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --query) query="$2"; shift 2 ;;
                --logical-resource-id) logical_id="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$service $operation" in
            'sso login')
                [ -z "${AWS_ACCESS_KEY_ID+x}" ] &&
                    [ -z "${AWS_SECRET_ACCESS_KEY+x}" ] &&
                    [ -z "${AWS_SESSION_TOKEN+x}" ] &&
                    [ "${AWS_PROFILE:-}" = dev-selected ] || exit 90
                ;;
            'cloudformation describe-stacks')
                case "$query" in
                    'Stacks[0].StackStatus')
                        if [ "${MOCK_STACK_STATUS:-}" = missing ]; then
                            printf 'Stack does not exist\n' >&2
                            exit 1
                        fi
                        printf '%s\n' "${MOCK_STACK_STATUS:-UPDATE_COMPLETE}"
                        ;;
                    *Parameters*)
                        printf 'EnableWireGuardGateway|false\tRetainTigerBeetleProcessorVpcCleanupResources|false\n'
                        ;;
                    *IntakeFunctionName*)
                        printf 'IntakeFunctionName|intake-lambda\tQueryFunctionName|query-lambda\t'
                        printf 'TigerBeetleProcessorName|tiger-beetle-processor\t'
                        printf 'TigerBeetleCompletionProcessorName|tiger-beetle-completion-processor\n'
                        ;;
                    *IntakeFunctionUrl*) printf 'https://intake.example.invalid/\n' ;;
                    *QueryFunctionUrl*) printf 'https://query.example.invalid/\n' ;;
                    *) printf 'unexpected AWS query: %s\n' "$query" >&2; exit 91 ;;
                esac
                ;;
            'cloudformation describe-stack-resource')
                case "$logical_id" in
                    IntakeFunction) printf 'intake-lambda\n' ;;
                    OperationsTable) printf 'mock-operations\n' ;;
                    TigerBeetleQueue) printf 'https://queue.example.invalid/\n' ;;
                    *) exit 92 ;;
                esac
                ;;
            'dynamodb wait') ;;
            'dynamodb describe-table')
                case "$query" in
                    'Table.'*) printf 'mock-operations ACTIVE PAY_PER_REQUEST 1 id S 1 id HASH 0 0\n' ;;
                    *) printf '{}\n' ;;
                esac
                ;;
            'sqs get-queue-attributes') printf '{}\n' ;;
            *) printf 'unexpected AWS command: %s\n' "$arguments" >&2; exit 93 ;;
        esac
        ;;
    *) exit 94 ;;
esac
MOCK
chmod +x "$TEST_TMP_DIR/bin/mock-command"
for command_name in aws sam zig file zip unzip curl; do
    ln -s mock-command "$TEST_TMP_DIR/bin/$command_name"
done

new_checkout() {
    CHECKOUT="$TEST_TMP_DIR/$1"
    mkdir -p "$CHECKOUT"
    cp "$REPOSITORY_ROOT/deploy.sh" "$CHECKOUT/deploy.sh"
    MOCK_CALL_LOG="$CHECKOUT/calls.log"
    : >"$MOCK_CALL_LOG"
    export MOCK_CALL_LOG
}

run_script() {
    env PATH="$TEST_TMP_DIR/bin:$PATH" \
        PROFILE=dev-selected REGION=ca-central-1 STACK_NAME=mock-stack \
        PASETO_PUBLIC_KEY="${MOCK_PUBLIC_KEY-mock-public}" \
        PASETO_PRIVATE_KEY="${MOCK_PRIVATE_KEY-mock-private}" \
        AWS_ACCESS_KEY_ID=inherited AWS_SECRET_ACCESS_KEY=inherited AWS_SESSION_TOKEN=inherited \
        bash "$CHECKOUT/deploy.sh" "$@" >"$CHECKOUT/output.log" 2>&1
}

test_full_deployment_baseline() {
    local calls stages expected
    new_checkout full
    mkdir -p "$CHECKOUT/.zig-cache-dev" "$CHECKOUT/.zig-global-cache-dev"
    touch "$CHECKOUT/.zig-cache-dev/previous" "$CHECKOUT/.zig-global-cache-dev/previous"
    run_script || fail_test "full deployment failed: $(cat "$CHECKOUT/output.log")"
    calls="$(cat "$MOCK_CALL_LOG")"
    stages="$(sed -n -e '/^zig /p' -e '/^sam /p' "$MOCK_CALL_LOG")"
    expected='zig fmt --check build.zig src/processor_message.zig src/tiger_beetle_completion_processor.zig src/tiger_beetle_processor.zig src/intake_lambda.zig src/lambda_auth.zig src/paseto.zig src/paseto_cli.zig src/query_lambda.zig
zig build test --cache-dir .zig-cache-deploy --global-cache-dir .zig-global-cache-deploy
zig build --cache-dir .zig-cache-deploy --global-cache-dir .zig-global-cache-deploy --release -Darch=arm
sam validate --template-file template.yaml --region ca-central-1
sam validate --lint --template-file template.yaml --region ca-central-1'
    assert_contains "$stages" "$expected"
    assert_contains "$calls" 'sam deploy --template-file template.yaml --stack-name mock-stack'
    assert_contains "$calls" 'EnableWireGuardGateway=false RetainTigerBeetleProcessorVpcCleanupResources=false'
    assert_contains "$calls" 'paseto issue --subject deploy-query-test-'
    [ "$(sed -n '1p' "$MOCK_CALL_LOG")" = 'aws sso login --profile dev-selected' ] ||
        fail_test 'full deployment did not authenticate first'
    [ "$(sed -n '/^curl /p' "$MOCK_CALL_LOG" | wc -l | tr -d ' ')" = 6 ] ||
        fail_test 'full deployment did not retain all six HTTP probes'
    [ ! -e "$CHECKOUT/.zig-cache-deploy" ] && [ ! -e "$CHECKOUT/.zig-global-cache-deploy" ] ||
        fail_test 'full deployment retained temporary caches'
    [ -f "$CHECKOUT/.zig-cache-dev/previous" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/previous" ] ||
        fail_test 'full deployment removed development caches'
}

test_development_dry_run() {
    local calls
    new_checkout dev-dry
    MOCK_PUBLIC_KEY='' MOCK_PRIVATE_KEY='' run_script --dev --dry-run ||
        fail_test "development dry run failed: $(cat "$CHECKOUT/output.log")"
    calls="$(cat "$MOCK_CALL_LOG")"
    assert_contains "$calls" 'zig fmt --check'
    assert_contains "$calls" 'zig build --cache-dir .zig-cache-dev --global-cache-dir .zig-global-cache-dev --release -Darch=arm'
    assert_contains "$calls" 'zip -qj tiger-beetle-completion-processor.zip'
    assert_not_contains "$calls" 'zig build test'
    assert_not_contains "$calls" 'aws '
    assert_not_contains "$calls" 'sam '
    [ -f "$CHECKOUT/.zig-cache-dev/retained" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/retained" ] ||
        fail_test 'development caches were not retained'
    touch "$CHECKOUT/.zig-cache-dev/previous" "$CHECKOUT/.zig-global-cache-dev/previous"
    run_script --dry-run --dev || fail_test 'repeated development dry run failed'
    [ -f "$CHECKOUT/.zig-cache-dev/previous" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/previous" ] ||
        fail_test 'repeated development run removed previous caches'
}

test_development_code_sync() {
    local calls
    new_checkout dev-sync
    MOCK_SAM_CONFIRMATION=1 run_script \
        --dev --profile=dev-selected --region us-east-1 --stack-name=dev-code-stack </dev/null ||
        fail_test "development sync failed: $(cat "$CHECKOUT/output.log")"
    calls="$(cat "$MOCK_CALL_LOG")"
    assert_contains "$calls" 'sam sync --template-file template.yaml --stack-name dev-code-stack --region us-east-1 --profile dev-selected --code --no-watch --no-dependency-layer --resource-id IntakeFunction --resource-id QueryFunction --resource-id TigerBeetleProcessor --resource-id TigerBeetleCompletionProcessor'
    assert_not_contains "$calls" 'sam deploy '
    assert_not_contains "$calls" 'sam validate '
    assert_not_contains "$calls" 'zig build test '
    assert_not_contains "$calls" 'Stacks[0].Parameters'
    assert_not_contains "$calls" '--parameter-overrides'
    assert_contains "$calls" 'aws cloudformation describe-stacks --stack-name dev-code-stack --query Stacks[0].StackStatus --output text --profile dev-selected --region us-east-1'
    [ "$(sed -n '1p' "$MOCK_CALL_LOG")" = 'aws sso login --profile dev-selected' ] ||
        fail_test 'development sync did not authenticate first'
    [ "$(sed -n '/^curl /p' "$MOCK_CALL_LOG" | wc -l | tr -d ' ')" = 6 ] ||
        fail_test 'development sync did not retain all six HTTP probes'
    [ -f "$CHECKOUT/.zig-cache-dev/retained" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/retained" ] ||
        fail_test 'development sync removed its caches'
}

test_development_rejects_configuration_and_lifecycle_options() {
    local option
    for option in \
        --intake-function-name --query-function-name \
        --tiger-beetle-processor-name --tiger-beetle-completion-processor-name \
        --tigerbeetle-cluster-id --tigerbeetle-addresses --lambda-principal
    do
        new_checkout invalid
        if run_script --dev "$option" ignored; then
            fail_test "development accepted configuration option: $option"
        fi
        [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'invalid development options performed work'
        assert_contains "$(cat "$CHECKOUT/output.log")" 'full deployment'
        if run_script "$option=ignored" --dev; then
            fail_test "development accepted configuration option before --dev: $option"
        fi
        [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'invalid development options performed work'
    done
    for option in --cleanup --disable --enable-wireguard-gateway --wireguard-ami-id=ami-00000001; do
        new_checkout invalid-lifecycle
        if run_script --dev "$option"; then
            fail_test "development accepted lifecycle option: $option"
        fi
        [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'invalid lifecycle options performed work'
    done
    new_checkout invalid-controller
    if DEPLOYMENT_CONTROLLER=wireguard_gateway_controller run_script --dev; then
        fail_test 'development accepted a WireGuard deployment controller'
    fi
    [ ! -s "$MOCK_CALL_LOG" ] || fail_test 'development controller rejection performed work'
    assert_contains "$(cat "$CHECKOUT/output.log")" 'full deployment'
}

test_development_gates_and_failure_propagation() {
    local failure
    for failure in zig:fmt zig:build file:zig-out/bin/intake/bootstrap zip:-qj unzip:-Z1 sam:sync; do
        new_checkout failure
        if MOCK_FAILURE="$failure" run_script --dev; then
            fail_test "development succeeded after command failure: $failure"
        fi
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'curl '
        if [ "$failure" != sam:sync ]; then
            assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam sync '
        fi
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy '
    done
    assert_contains "$(cat "$CHECKOUT/output.log")" 'some functions may already have updated'
    [ -f "$CHECKOUT/.zig-cache-dev/retained" ] && [ -f "$CHECKOUT/.zig-global-cache-dev/retained" ] ||
        fail_test 'failed development sync removed its caches'

    new_checkout invalid-bootstrap
    if MOCK_BAD_BOOTSTRAP=1 run_script --dev --dry-run; then
        fail_test 'development accepted an invalid bootstrap'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'unexpected bootstrap artifact type'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zip '

    new_checkout invalid-archive
    if MOCK_ARCHIVE_CONTENTS='nested/bootstrap' run_script --dev --dry-run; then
        fail_test 'development accepted an invalid archive'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'must contain only a root-level bootstrap'

    new_checkout failed-smoke
    if MOCK_HTTP_STATUS=500 run_script --dev; then
        fail_test 'development accepted a failing HTTP smoke check'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'expected 401'
}

test_development_authentication_and_stack_guards() {
    local status
    for status in UPDATE_IN_PROGRESS missing; do
        new_checkout stack-guard
        if MOCK_STACK_STATUS="$status" run_script --dev; then
            fail_test "development accepted stack status: $status"
        fi
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zig '
        assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam '
    done
    assert_contains "$(cat "$CHECKOUT/output.log")" 'run a full deployment first'
    new_checkout failed-login
    if MOCK_FAILURE=aws:sso run_script --dev; then
        fail_test 'development accepted failed SSO login'
    fi
    [ "$(cat "$MOCK_CALL_LOG")" = 'aws sso login --profile dev-selected' ] ||
        fail_test 'development proceeded after failed authentication'
}

test_development_prerequisites_and_smoke_opt_out() {
    new_checkout wrong-zig
    if MOCK_ZIG_VERSION=0.15.2 run_script --dev --dry-run; then
        fail_test 'development accepted the wrong Zig version'
    fi
    assert_contains "$(cat "$CHECKOUT/output.log")" 'require Zig 0.16.0'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zig build '

    new_checkout missing-stdlib
    rm "$TEST_TMP_DIR/zig/lib/std/Io/net/HostName.zig"
    if run_script --dev --dry-run; then
        fail_test 'development accepted a missing sibling standard library'
    fi
    touch "$TEST_TMP_DIR/zig/lib/std/Io/net/HostName.zig"
    assert_contains "$(cat "$CHECKOUT/output.log")" 'required sibling Zig standard library missing'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zig build '

    new_checkout no-smoke
    MOCK_PUBLIC_KEY='' MOCK_PRIVATE_KEY='' run_script --dev --no-url-check ||
        fail_test 'development smoke opt-out still required PASETO keys'
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'sam sync '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'curl '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'paseto '
}

test_full_dry_run_and_failed_build_cleanup() {
    new_checkout full-dry
    run_script --dry-run || fail_test 'ordinary dry run failed'
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'zig build test '
    assert_contains "$(cat "$MOCK_CALL_LOG")" 'sam validate --lint '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'aws '
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'sam deploy '
    [ ! -e "$CHECKOUT/.zig-cache-deploy" ] && [ ! -e "$CHECKOUT/.zig-global-cache-deploy" ] ||
        fail_test 'ordinary dry run retained temporary caches'

    new_checkout full-failure
    mkdir -p "$CHECKOUT/.zig-cache-deploy" "$CHECKOUT/.zig-global-cache-deploy"
    if MOCK_FAILURE=zig:build run_script --dry-run; then
        fail_test 'full deployment succeeded after failed tests'
    fi
    [ ! -e "$CHECKOUT/.zig-cache-deploy" ] && [ ! -e "$CHECKOUT/.zig-global-cache-deploy" ] ||
        fail_test 'failed full deployment retained temporary caches'
    assert_not_contains "$(cat "$MOCK_CALL_LOG")" 'zip '
}

test_full_deployment_baseline
test_development_dry_run
test_development_code_sync
test_development_rejects_configuration_and_lifecycle_options
test_development_gates_and_failure_propagation
test_development_authentication_and_stack_guards
test_development_prerequisites_and_smoke_opt_out
test_full_dry_run_and_failed_build_cleanup
printf 'PASS: development deployment regression tests\n'
