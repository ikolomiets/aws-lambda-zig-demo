#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/seat-scenarios-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/repo/zig-out/bin" "$TEST_DIR/bin" "$TEST_DIR/state"
cp "$REPOSITORY_ROOT/seat_scenarios.sh" "$TEST_DIR/repo/"
export FIXTURE_DIR="$TEST_DIR/state" AWS_CALLS="$TEST_DIR/aws-calls"
export PATH="$TEST_DIR/bin:$PATH"
# Never inherit the operator's AWS configuration or bearer tokens into fixtures.
while IFS= read -r key; do unset "$key"; done < <(compgen -e | sed -n '/^AWS_/p')
export AWS_CALLS="$TEST_DIR/aws-calls" AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
unset PROFILE REGION STACK_NAME OUTPUT_DIR PASETO_PRIVATE_KEY PASETO_TOKEN PASETO_FOREIGN_TOKEN
: >"$AWS_CALLS"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail_test "missing: $2" ;; esac; }

cat >"$TEST_DIR/mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${PASETO_TOKEN:-}${PASETO_FOREIGN_TOKEN:-}${PASETO_PRIVATE_KEY:-}" ] || exit 90
case "${0##*/}" in
    aws)
        printf '%s | profile=%s region=%s\n' "$*" "${AWS_PROFILE:-}" "${AWS_REGION:-}" >>"$AWS_CALLS"
        case "$1 $2" in
            'configure export-credentials')
                [ "${AWS_ACCESS_KEY_ID:-}" = "${EXPECTED_ACCESS_KEY:-}" ] || exit 91
                [ "${AWS_SESSION_TOKEN:-}" = "${EXPECTED_SESSION_TOKEN:-}" ] || exit 92
                if [ "${STATIC_CREDENTIALS:-false}" = true ]; then
                    printf '%s\n' '{"AccessKeyId":"fixture-access","SecretAccessKey":"fixture-secret"}'
                else
                    printf '%s\n' '{"AccessKeyId":"fixture-access","SecretAccessKey":"fixture-secret","SessionToken":"fixture-session"}'
                fi ;;
            'cloudformation describe-stacks')
                cat <<'JSON'
{"Stacks":[{"Outputs":[
  {"OutputKey":"IntakeFunctionUrl","OutputValue":"https://intake.invalid/"},
  {"OutputKey":"QueryFunctionUrl","OutputValue":"https://query.invalid/"},
  {"OutputKey":"SeatEventsTableName","OutputValue":"fixture-events"},
  {"OutputKey":"LedgerCounterTableName","OutputValue":"fixture-counter"},
  {"OutputKey":"LedgerCounterId","OutputValue":"fixture-sequence"}
]}]}
JSON
                ;;
            'cloudformation describe-stack-resource')
                printf '%s\n' '{"StackResourceDetail":{"PhysicalResourceId":"fixture-operations"}}' ;;
            *) exit 93 ;;
        esac ;;
    curl)
        config="$(cat)"
        url="$(printf '%s\n' "$config" | sed -n 's/^url = //p' | jq -r .)"
        method="$(printf '%s\n' "$config" | sed -n 's/^request = //p' | jq -r .)"
        header="$(printf '%s\n' "$config" | sed -n '/^header = .*Authorization:/s/^header = //p' | jq -r .)"
        if [ -z "$header" ]; then printf '{}\n401\n'; exit; fi
        case "$header" in
            'Authorization: Bearer v4.public.owner') tenant=fixture-owner ;;
            'Authorization: Bearer v4.public.foreign') tenant=fixture-foreign ;;
            *) exit 94 ;;
        esac
        if [ "$tenant" = fixture-owner ] && [ "${REJECT_OWNER_TOKEN:-false}" = true ]; then
            printf '{}\n401\n'; exit
        fi
        if [ "$method" = GET ]; then
            operation="$FIXTURE_DIR/${url##*/}.json"
            if [ -f "$operation" ] && [ "$(jq -r .tenant "$operation")" = "$tenant" ]; then
                cat "$operation"; printf '\n200\n'
            else
                printf 'Not Found\n\n404\n'
            fi
            exit
        fi
        request="$(printf '%s\n' "$config" | sed -n 's/^data = //p' | jq -r .)"
        id="$(printf '%s' "$request" | jq -r .id)"
        if [ -f "$FIXTURE_DIR/$id.json" ]; then printf '{}\n409\n'; exit; fi
        command="$(printf '%s' "$request" | jq -r .body.command)"
        event_id="$(printf '%s' "$request" | jq -r '.body.event_id // .id')"
        result_type=SUCCESS
        if [ "$tenant" = fixture-foreign ]; then
            payload='{"code":"event_unavailable"}'; result_type=FAILURE
        else
            case "$command" in
                create_event)
                    payload="$(jq -cn --arg id "$id" '{event_id:$id}')"
                    jq -n --arg id "$id" --arg tenant "$tenant" '{
                        tenant:$tenant,event_id:$id,ledger:1001,timeout_seconds:300,
                        capacity_account_id:"1",allocation_account_id:"2",state:"ready",
                        classes:{general:{total:3,tb_account_id:"3"},premium:{total:2,tb_account_id:"4"}}
                    }' >"$FIXTURE_DIR/event.json" ;;
                check_seats)
                    available=3
                    [ ! -f "$FIXTURE_DIR/reserved" ] || available=1
                    payload="$(jq -cn --arg id "$event_id" --argjson n "$available" \
                        '{event_id:$id,classes:{general:{total:3,available:$n},premium:{total:2,available:2}}}')" ;;
                reserve_seats)
                    : >"$FIXTURE_DIR/reserved"
                    payload="$(jq -cn --arg id "$event_id" \
                        '{event_id:$id,class:"general",quantity:2,reservation_id:"5"}')" ;;
                confirm_seats)
                    payload="$(jq -cn --arg id "$event_id" \
                        '{event_id:$id,class:"general",reservation_id:"5"}')" ;;
                *) exit 95 ;;
            esac
        fi
        jq -n --arg id "$id" --arg tenant "$tenant" --arg type "$result_type" --argjson payload "$payload" '{
            id:$id,tenant:$tenant,name:"SeatReservation",state:"COMPLETED",hash:("a"*64),
            last_updated:1,expires_at:2,result:{type:$type,payload:$payload}
        }' >"$FIXTURE_DIR/$id.json"
        cat "$FIXTURE_DIR/$id.json"; printf '\n200\n' ;;
    events|dynamodb|ledger-counter)
        [ "${AWS_ACCESS_KEY_ID:-}" = fixture-access ] || exit 96
        [ "${AWS_SECRET_ACCESS_KEY:-}" = fixture-secret ] || exit 97
        [ "${AWS_CONFIG_FILE:-}" = /dev/null ] && [ "${AWS_SHARED_CREDENTIALS_FILE:-}" = /dev/null ] || exit 98
        if [ "${STATIC_CREDENTIALS:-false}" = true ]; then
            [ -z "${AWS_SESSION_TOKEN:-}" ] || exit 99
        else
            [ "${AWS_SESSION_TOKEN:-}" = fixture-session ] || exit 99
        fi
        case "${0##*/}" in
            events) cat "$FIXTURE_DIR/event.json" ;;
            dynamodb) cat "$FIXTURE_DIR/$3.json" ;;
            ledger-counter)
                [ "$1" = --counter-id ] && [ "$2" = fixture-sequence ] || exit 100
                high_water=1000
                [ ! -f "$FIXTURE_DIR/event.json" ] || high_water=1001
                jq -n --argjson n "$high_water" '{counter_id:"fixture-sequence",high_water:$n}' ;;
        esac ;;
    *) exit 101 ;;
esac
MOCK
chmod +x "$TEST_DIR/mock"
for tool in aws curl; do cp "$TEST_DIR/mock" "$TEST_DIR/bin/$tool"; done
for tool in events dynamodb ledger-counter; do cp "$TEST_DIR/mock" "$TEST_DIR/repo/zig-out/bin/$tool"; done
cd "$TEST_DIR/repo"

output="$(bash ./seat_scenarios.sh --help)"
contains "$output" 'PASETO_TOKEN'
export PASETO_TOKEN=v4.public.owner
for arguments in '--unknown' '--profile' '--region --stack-name other' '--poll-attempts 0' '--timeout-seconds -1' '--profile=' '--output-dir='; do
    exit_code=0
    # These fixed test arguments contain no whitespace-bearing option values.
    bash ./seat_scenarios.sh $arguments >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr" || exit_code=$?
    [ "$exit_code" -eq 2 ] || fail_test "invalid arguments did not exit 2"
    contains "$(cat "$TEST_DIR/stderr")" 'Usage:'
    [ ! -s "$TEST_DIR/stdout" ] || fail_test 'argument error wrote to stdout'
done
[ ! -s "$AWS_CALLS" ] || fail_test 'help or invalid arguments contacted AWS'

run_scenarios() {
    rm -f "$FIXTURE_DIR"/*
    : >"$AWS_CALLS"
    if ! bash ./seat_scenarios.sh "$@" >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
        cat "$TEST_DIR/stderr" >&2
        fail_test 'mocked scenarios failed'
    fi
}
run_scenarios
manifest="$(find .scratch -name manifest.json -print)"
[ -n "$manifest" ] || fail_test 'default evidence directory missing'
jq -e '.status == "passed" and .tenant_isolation == "skipped" and
    .tenants == ["fixture-owner"] and (.operations|length) == 6' "$manifest" >/dev/null
contains "$(cat "$AWS_CALLS")" '--stack-name aws-lambda-zig-demo --region ca-central-1'
if [[ "$(cat "$AWS_CALLS")" == *--profile* ]]; then fail_test 'default AWS chain forced a profile'; fi
contains "$(cat "$TEST_DIR/stdout")" '.scratch/seat-scenarios.'
run_scenarios
[ "$(find .scratch -name manifest.json | wc -l | tr -d ' ')" = 2 ] || fail_test 'default output was reused'

export AWS_PROFILE=environment-profile AWS_REGION=environment-region AWS_DEFAULT_REGION=ignored-region
export PROFILE=ignored-profile REGION=ignored-region STACK_NAME=environment-stack OUTPUT_DIR="$TEST_DIR/environment-output"
export AWS_ACCESS_KEY_ID=inherited-access AWS_SECRET_ACCESS_KEY=inherited-secret AWS_SESSION_TOKEN=inherited-session
export EXPECTED_ACCESS_KEY=inherited-access EXPECTED_SESSION_TOKEN=inherited-session
export PASETO_FOREIGN_TOKEN=v4.public.foreign
run_scenarios
contains "$(cat "$AWS_CALLS")" 'profile=environment-profile region=environment-region'
contains "$(cat "$AWS_CALLS")" '--stack-name environment-stack --region environment-region'
if [[ "$(cat "$AWS_CALLS")" == *--profile* ]]; then fail_test 'inherited AWS profile forced CLI credential precedence'; fi
jq -e '.status == "passed" and .tenant_isolation == "passed" and
    .tenants == ["fixture-owner","fixture-foreign"] and (.operations|length) == 9' "$OUTPUT_DIR/manifest.json" >/dev/null

export STATIC_CREDENTIALS=true
unset PASETO_FOREIGN_TOKEN
run_scenarios --authorize-cloud --profile selected-profile --region=selected-region \
    --stack-name selected-stack --output-dir "$TEST_DIR/explicit-output"
contains "$(cat "$AWS_CALLS")" '--profile selected-profile'
contains "$(cat "$AWS_CALLS")" '--stack-name selected-stack --region selected-region'
jq -e '.status == "passed"' "$TEST_DIR/explicit-output/manifest.json" >/dev/null
if grep -Erq 'v4\.public\.|fixture-secret|fixture-session|inherited-secret' .scratch "$OUTPUT_DIR" "$TEST_DIR/explicit-output"; then
    fail_test 'evidence contains credentials or tokens'
fi

# Both the AWS fallbacks and the repository's older selector names remain usable.
unset AWS_PROFILE AWS_REGION
export AWS_DEFAULT_PROFILE=fallback-profile AWS_DEFAULT_REGION=fallback-region
run_scenarios --output-dir "$TEST_DIR/fallback-output"
contains "$(cat "$AWS_CALLS")" 'profile=fallback-profile region=fallback-region'
unset AWS_DEFAULT_PROFILE AWS_DEFAULT_REGION
export PROFILE=legacy-profile REGION=legacy-region
run_scenarios --output-dir "$TEST_DIR/legacy-output"
contains "$(cat "$AWS_CALLS")" 'profile=legacy-profile region=legacy-region'

: >"$AWS_CALLS"
for token in '' 'not-a-token' $'v4.public.owner\n'; do
    exit_code=0
    PASETO_TOKEN="$token" bash ./seat_scenarios.sh >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr" || exit_code=$?
    [ "$exit_code" -eq 2 ] || fail_test 'missing or malformed token did not exit 2'
    contains "$(cat "$TEST_DIR/stderr")" 'PASETO_TOKEN must be a v4.public token'
    contains "$(cat "$TEST_DIR/stderr")" 'Usage:'
done
exit_code=0
PASETO_FOREIGN_TOKEN="$PASETO_TOKEN" bash ./seat_scenarios.sh >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr" || exit_code=$?
[ "$exit_code" -eq 2 ] || fail_test 'identical owner and foreign tokens accepted'
[ ! -s "$AWS_CALLS" ] || fail_test 'invalid tokens contacted AWS'

exit_code=0
bash ./seat_scenarios.sh --output-dir "$TEST_DIR/legacy-output" \
    >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr" || exit_code=$?
[ "$exit_code" -eq 2 ] || fail_test 'existing evidence directory was accepted'
contains "$(cat "$TEST_DIR/stderr")" 'Usage:'
[ ! -s "$AWS_CALLS" ] || fail_test 'existing evidence directory contacted AWS'

exit_code=0
REJECT_OWNER_TOKEN=true bash ./seat_scenarios.sh --output-dir "$TEST_DIR/rejected-token-output" \
    >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr" || exit_code=$?
[ "$exit_code" -eq 1 ] || fail_test 'rejected token did not fail the workflow'
contains "$(cat "$TEST_DIR/stderr")" 'unexpected HTTP status 401 (expected 200)'
jq -e '.status == "failed" and (.stage|startswith("create intake"))' \
    "$TEST_DIR/rejected-token-output/manifest.json" >/dev/null
printf 'Seat scenario environment, token, argument, and workflow tests passed.\n'
