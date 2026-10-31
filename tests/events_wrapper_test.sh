#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/events-wrapper-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/repo/zig-out/bin" "$TEST_DIR/bin"
cp "$REPOSITORY_ROOT/events.sh" "$TEST_DIR/repo/"
while IFS= read -r key; do unset "$key"; done < <(compgen -e | sed -n '/^AWS_/p')
unset PROFILE REGION STACK_NAME PASETO_TOKEN PASETO_FOREIGN_TOKEN PASETO_PRIVATE_KEY
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export PATH="$TEST_DIR/bin:$PATH" AWS_CALLS="$TEST_DIR/aws-calls" REQUEST_FILE="$TEST_DIR/request"
export HTTP_CALLS="$TEST_DIR/http-calls" SLEEP_CALLS="$TEST_DIR/sleep-calls" QUERY_COUNT="$TEST_DIR/query-count"
export SSO_MARKER="$TEST_DIR/sso-refreshed"
export EVENT_ID=00000000-0000-0000-0000-000000000001
: >"$AWS_CALLS"
: >"$HTTP_CALLS"
: >"$SLEEP_CALLS"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail_test "missing: $2" ;; esac; }
run_events() { bash "$TEST_DIR/repo/events.sh" "$@"; }
reject() {
    : >"$AWS_CALLS"
    : >"$HTTP_CALLS"
    if run_events "$@" >"$TEST_DIR/output" 2>&1; then fail_test 'accepted invalid arguments'
    else [ "$?" -eq 2 ] || fail_test 'invalid arguments returned the wrong exit code'; fi
    [ ! -s "$AWS_CALLS" ] || fail_test 'invalid arguments contacted AWS'
    [ ! -s "$HTTP_CALLS" ] || fail_test 'invalid arguments contacted HTTP endpoints'
}

cat >"$TEST_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${PASETO_TOKEN:-}${PASETO_FOREIGN_TOKEN:-}${PASETO_PRIVATE_KEY:-}" ] || exit 90
printf '%s | profile=%s region=%s\n' "$*" "${AWS_PROFILE:-}" "${AWS_REGION:-}" >>"$AWS_CALLS"
[ "${AWS_REGION:-}" = "${EXPECTED_REGION:-ca-central-1}" ] || exit 91
[ "${AWS_DEFAULT_REGION:-}" = "$AWS_REGION" ] || exit 92
case "$1 $2" in
    'configure export-credentials')
        [ "${AWS_ACCESS_KEY_ID:-}" = "${EXPECTED_ACCESS_KEY:-}" ] || exit 93
        [ "${AWS_SESSION_TOKEN:-}" = "${EXPECTED_SESSION_TOKEN:-}" ] || exit 94
        if [ "${EXPIRED_SSO:-false}" = true ] && [ ! -f "$SSO_MARKER" ]; then
            printf 'Error when retrieving token from sso: Token has expired and refresh failed\n' >&2
            exit 255
        fi
        if [ "${EXPORT_FAILURE:-false}" = true ]; then exit 255; fi
        if [ "${BAD_CREDENTIALS:-false}" = true ]; then printf '{}\n'; exit; fi
        if [ "${STATIC_CREDENTIALS:-false}" = true ]; then
            printf '%s\n' '{"AccessKeyId":"fixture-access","SecretAccessKey":"fixture-secret"}'
        else
            printf '%s\n' '{"AccessKeyId":"fixture-access","SecretAccessKey":"fixture-secret","SessionToken":"fixture-session"}'
        fi ;;
    'configure get')
        case "${SSO_CONFIG:-none}:$3" in
            modern:sso_session) printf 'fixture-session\n' ;;
            legacy:sso_start_url) printf 'https://sso.invalid/start\n' ;;
            *) exit 1 ;;
        esac ;;
    'sso login')
        if [ "${LOGIN_FAILURE:-false}" = true ]; then exit 255; fi
        printf 'fixture SSO sign-in instructions\n'
        : >"$SSO_MARKER" ;;
    'cloudformation describe-stack-resource') printf 'fixture-events\n' ;;
    'cloudformation describe-stacks')
        case "$*" in
            *QueryFunctionUrl*) printf '%s\n' "${QUERY_URL:-https://query.invalid/}" ;;
            *) printf '%s\n' "${INTAKE_URL:-https://intake.invalid/}" ;;
        esac ;;
    *) exit 95 ;;
esac
MOCK
cat >"$TEST_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = '--disable --config -' ] || exit 90
[ -z "${PASETO_TOKEN:-}${PASETO_FOREIGN_TOKEN:-}${PASETO_PRIVATE_KEY:-}" ] || exit 91
config="$(cat)"
url="$(printf '%s\n' "$config" | sed -n 's/^url = //p' | jq -r .)"
method="$(printf '%s\n' "$config" | sed -n 's/^request = //p' | jq -r .)"
printf '%s %s\n' "$method" "$url" >>"$HTTP_CALLS"
header="$(printf '%s\n' "$config" | sed -n '/^header = .*Authorization:/s/^header = //p' | jq -r .)"
[ "$header" = 'Authorization: Bearer v4.public.fixture' ] || exit 93
state=SUBMITTED
tenant="${RESPONSE_TENANT-fixture-owner}"
case "$method" in
    POST)
        [ "$url" = https://intake.invalid/ ] || exit 92
        printf '%s\n' "$config" | sed -n 's/^data = //p' | jq -r . >"$REQUEST_FILE"
        printf '0\n' >"$QUERY_COUNT"
        if [ "${CURL_FAILURE:-false}" = true ]; then exit 7; fi
        if [ "${BAD_RESPONSE:-false}" = true ]; then printf '{}\n200\n'; exit; fi
        status="${HTTP_STATUS:-200}" ;;
    GET)
        operation_id="$(jq -r .id "$REQUEST_FILE")"
        [ "$url" = "https://query.invalid/$operation_id" ] || exit 94
        case "$config" in *'data = '*) exit 95 ;; esac
        if [ "${QUERY_CURL_FAILURE:-false}" = true ]; then exit 7; fi
        if [ "${BAD_QUERY_RESPONSE:-false}" = true ]; then printf '{}\n200\n'; exit; fi
        if [ "${EXTRA_QUERY_RESPONSE:-false}" = true ]; then printf 'null\n'; fi
        count="$(cat "$QUERY_COUNT")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$QUERY_COUNT"
        if [ "$count" -gt "${SUBMITTED_READS:-2}" ]; then state=COMPLETED; fi
        tenant="${QUERY_TENANT:-$tenant}"
        status="${QUERY_HTTP_STATUS:-200}" ;;
    *) exit 96 ;;
esac
jq -c --arg state "$state" --arg tenant "$tenant" --arg type "${RESULT_TYPE:-SUCCESS}" \
    --arg code "${RESULT_CODE:-event_unavailable}" \
    --arg id "${QUERY_OPERATION_ID:-}" --arg name "${QUERY_OPERATION_NAME:-SeatReservation}" \
    --argjson missing "${MISSING_RESULT:-false}" '
    {id:.id,name:.name,tenant:$tenant,state:$state} +
    (if $state == "COMPLETED" and ($missing|not) then
        {result:{type:$type,payload:(if $type == "FAILURE" then {code:$code}
            elif .body.command == "reserve_seats" then
                {event_id:.body.event_id,class:.body.class,quantity:.body.quantity,reservation_id:"123"}
            else {event_id:.body.event_id,classes:{general:{total:100,available:97}}} end)}}
     else {} end)
    | if $state == "COMPLETED" then
        .name = $name | if $id != "" then .id = $id else . end
      else . end
    ' "$REQUEST_FILE"
printf '%s\n' "$status"
MOCK
cat >"$TEST_DIR/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 1 ] && [ "$1" = 1 ] || exit 90
printf '%s\n' "$1" >>"$SLEEP_CALLS"
MOCK
chmod +x "$TEST_DIR/bin/aws" "$TEST_DIR/bin/curl" "$TEST_DIR/bin/sleep"

# Help and bad invocations require no credentials, binary, or cloud discovery.
for args in help create read check_seats reserve_seat; do
    if [ "$args" = help ]; then run_events --help >/dev/null
    else run_events "$args" --help >/dev/null; fi
done
[ ! -s "$AWS_CALLS" ] || fail_test 'help contacted AWS'
reject create
reject create --class general=3
export PASETO_TOKEN=v4.public.fixture
for class in general general=0 general=-1 general=1.5 general=4294967296 capacity=1 allocation=1 '=1'; do
    reject create --class "$class"
done
reject create --class general=3 --class general=4
reject create --class general=3 --timeout-seconds=0
reject create --class general=3 --event-id=bad
reject create --class general=3 --tenant=override
reject --profile= create --class general=3
reject --region --stack-name stack create --class general=3
reject read --event-id "$EVENT_ID"
reject check_seats
reject check_seats --tenant fixture-owner
reject check_seats --event-id bad
reject check_seats --event-id "$EVENT_ID" --event-id "$EVENT_ID"
reject check_seats --event-id "$EVENT_ID" --class general=1
reject check_seats --event-id "$EVENT_ID" --timeout-seconds 30
PASETO_TOKEN= reject check_seats --event-id "$EVENT_ID"
PASETO_TOKEN=malformed reject check_seats --event-id "$EVENT_ID"
reject reserve_seat
reject reserve_seat --event-id "$EVENT_ID"
reject reserve_seat --event-id "$EVENT_ID" --class general
reject reserve_seat --event-id "$EVENT_ID" --quantity 2
reject reserve_seat --class general --quantity 2
reject reserve_seat --event-id bad --class general --quantity 2
reject reserve_seat --event-id "$EVENT_ID" --event-id "$EVENT_ID" --class general --quantity 2
reject reserve_seat --event-id "$EVENT_ID" --class general --class premium --quantity 2
reject reserve_seat --event-id "$EVENT_ID" --class general --quantity 2 --quantity 3
reject reserve_seat --event-id "$EVENT_ID" --class general --quantity 2 --tenant override
reject reserve_seat --event-id "$EVENT_ID" --class general --quantity 2 --timeout-seconds 30
reject reserve_seat --event-id "$EVENT_ID" --class general --quantity
reject reserve_seat --event-id "$EVENT_ID" --class --quantity 2
reject reserve_seat --event-id "$EVENT_ID" --class= --quantity 2
for quantity in '' 0 -1 1.5 1e2 4294967296 invalid; do
    reject reserve_seat --event-id "$EVENT_ID" --class general --quantity="$quantity"
done
for tag in capacity allocation $'bad\nclass' $'bad\177class' $'bad\302\200class' \
    $'bad\377class' $'bad\300\257class' \
    "$(printf '%055d' 0)" "$(printf 'é%.0s' {1..28})"; do
    reject reserve_seat --event-id "$EVENT_ID" --class "$tag" --quantity 2
done
PASETO_TOKEN= reject reserve_seat --event-id "$EVENT_ID" --class general --quantity 2
PASETO_TOKEN=malformed reject reserve_seat --event-id "$EVENT_ID" --class general --quantity 2
reject create --class general=3 --quantity 2
reject read --tenant fixture-owner --event-id "$EVENT_ID" --quantity 2
reject check_seats --event-id "$EVENT_ID" --quantity 2

# Creation has no host-binary prerequisite and uses explicit classes, with no stdin.
output="$(run_events create --class general=100 --class premium=25 --event-id "$EVENT_ID" </dev/null)"
printf '%s' "$output" | jq -e --arg id "$EVENT_ID" \
    '.id == $id and .tenant == "fixture-owner" and .state == "SUBMITTED"' >/dev/null
jq -e --arg id "$EVENT_ID" '. == {id:$id,name:"SeatReservation",body:{command:"create_event",
    classes:{general:100,premium:25},timeout_seconds:300}}' "$REQUEST_FILE" >/dev/null
calls="$(cat "$AWS_CALLS")"
contains "$calls" 'configure export-credentials --format process'
contains "$calls" 'profile= region=ca-central-1'
case "$calls" in *--profile*) fail_test 'default chain forced a profile' ;; esac
case "$calls" in *'sso login'*) fail_test 'valid credentials triggered SSO login' ;; esac

output="$(run_events create --class='A=B=7' --class='é=2' --timeout-seconds=600)"
jq -e '.body.classes == {"A=B":7,"é":2} and .body.timeout_seconds == 600 and
    (.id|test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))' \
    "$REQUEST_FILE" >/dev/null

# Checks create distinct Operations without a host binary, then poll the same identity.
: >"$AWS_CALLS"
: >"$HTTP_CALLS"
: >"$SLEEP_CALLS"
output="$(run_events --stack-name check-stack check_seats \
    --tenant ignored-owner --event-id "$EVENT_ID" </dev/null)"
jq -e --arg event "$EVENT_ID" '.body == {command:"check_seats",event_id:$event} and
    .name == "SeatReservation" and .id != $event and
    (.id|test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    (keys == ["body","id","name"])' "$REQUEST_FILE" >/dev/null
operation_id="$(jq -r .id "$REQUEST_FILE")"
printf '%s' "$output" | jq -se --arg id "$operation_id" --arg event "$EVENT_ID" 'length == 3 and
    all(.[]; .id == $id and .tenant == "fixture-owner") and
    map(.state) == ["SUBMITTED","SUBMITTED","COMPLETED"] and
    .[-1].result == {type:"SUCCESS",payload:{event_id:$event,classes:{general:{total:100,available:97}}}}' >/dev/null
[ "$(cat "$QUERY_COUNT")" = 3 ] || fail_test 'check did not poll until completion'
[ "$(wc -l <"$SLEEP_CALLS" | tr -d ' ')" = 2 ] || fail_test 'check did not wait between submitted reads'
[ "$(cat "$HTTP_CALLS")" = "$(printf 'POST https://intake.invalid/\nGET https://query.invalid/%s\nGET https://query.invalid/%s\nGET https://query.invalid/%s' \
    "$operation_id" "$operation_id" "$operation_id")" ] || fail_test 'unexpected check HTTP calls'
calls="$(cat "$AWS_CALLS")"
contains "$calls" IntakeFunctionUrl
contains "$calls" QueryFunctionUrl
contains "$calls" '--stack-name check-stack'
case "$calls" in *describe-stack-resource*) fail_test 'check read Event metadata' ;; esac

# Each invocation observes seats through a new Operation, including terminal failures.
previous_id="$operation_id"
: >"$SLEEP_CALLS"
output="$(SUBMITTED_READS=0 RESULT_TYPE=FAILURE run_events check_seats \
    --tenant=ignored-owner --event-id="$EVENT_ID")"
printf '%s' "$output" | jq -e --arg previous "$previous_id" '.id != $previous and
    .tenant == "fixture-owner" and .state == "COMPLETED" and
    .result == {type:"FAILURE",payload:{code:"event_unavailable"}}' >/dev/null
[ ! -s "$SLEEP_CALLS" ] || fail_test 'check slept after completion'

# Reservations use the public intake and query path without a host binary.
: >"$AWS_CALLS"
: >"$HTTP_CALLS"
: >"$SLEEP_CALLS"
output="$(run_events --profile reserve-profile --region ca-central-1 --stack-name reserve-stack \
    reserve_seat --event-id "$EVENT_ID" --class general --quantity 2 </dev/null)"
jq -e --arg event "$EVENT_ID" '.body == {command:"reserve_seats",event_id:$event,class:"general",quantity:2} and
    .name == "SeatReservation" and .id != $event and
    (.id|test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    (keys == ["body","id","name"])' "$REQUEST_FILE" >/dev/null
operation_id="$(jq -r .id "$REQUEST_FILE")"
printf '%s' "$output" | jq -se --arg id "$operation_id" --arg event "$EVENT_ID" 'length == 3 and
    all(.[]; .id == $id and .tenant == "fixture-owner") and
    map(.state) == ["SUBMITTED","SUBMITTED","COMPLETED"] and
    .[-1].result == {type:"SUCCESS",payload:{event_id:$event,class:"general",quantity:2,reservation_id:"123"}}' >/dev/null
[ "$(cat "$QUERY_COUNT")" = 3 ] || fail_test 'reserve did not poll until completion'
[ "$(wc -l <"$SLEEP_CALLS" | tr -d ' ')" = 2 ] || fail_test 'reserve did not wait between submitted reads'
[ "$(cat "$HTTP_CALLS")" = "$(printf 'POST https://intake.invalid/\nGET https://query.invalid/%s\nGET https://query.invalid/%s\nGET https://query.invalid/%s' \
    "$operation_id" "$operation_id" "$operation_id")" ] || fail_test 'unexpected reserve HTTP calls'
calls="$(cat "$AWS_CALLS")"
contains "$calls" IntakeFunctionUrl
contains "$calls" QueryFunctionUrl
contains "$calls" '--profile reserve-profile'
contains "$calls" '--region ca-central-1'
contains "$calls" '--stack-name reserve-stack'
case "$calls" in *describe-stack-resource*) fail_test 'reserve read Event metadata' ;; esac

# Each invocation creates a new reservation Operation; a completed failure exits 0.
previous_id="$operation_id"
: >"$SLEEP_CALLS"
output="$(SUBMITTED_READS=0 RESULT_TYPE=FAILURE RESULT_CODE=insufficient_seats run_events \
    reserve_seat --event-id="$EVENT_ID" --class=general --quantity=2)"
printf '%s' "$output" | jq -e --arg previous "$previous_id" '.id != $previous and
    .tenant == "fixture-owner" and .state == "COMPLETED" and
    .result == {type:"FAILURE",payload:{code:"insufficient_seats"}}' >/dev/null
[ ! -s "$SLEEP_CALLS" ] || fail_test 'reserve slept after completion'

# Scalar tags retain their exact UTF-8 bytes and punctuation; quantity spans positive u32.
for tag in 'A=B' ' é "premium" \' "$(printf 'é%.0s' {1..27})"; do
    output="$(SUBMITTED_READS=0 run_events reserve_seat --event-id "$EVENT_ID" --class "$tag" --quantity 1)"
    jq -e --arg tag "$tag" '.body.class == $tag and .body.quantity == 1' "$REQUEST_FILE" >/dev/null
    printf '%s' "$output" | jq -e --arg tag "$tag" '.result.payload.class == $tag' >/dev/null
done
output="$(SUBMITTED_READS=0 run_events reserve_seat --event-id="$EVENT_ID" --class=general --quantity=4294967295)"
jq -e '.body.quantity == 4294967295' "$REQUEST_FILE" >/dev/null
printf '%s' "$output" | jq -e '.result.payload.quantity == 4294967295' >/dev/null

# Expired modern and legacy SSO sessions refresh using the selected identity.
for source in cli aws default legacy chain; do
    (
        : >"$AWS_CALLS"
        : >"$HTTP_CALLS"
        rm -f "$SSO_MARKER"
        export EXPIRED_SSO=true SSO_CONFIG=modern SUBMITTED_READS=0
        case "$source" in
            cli) export AWS_PROFILE=ignored ;;
            aws) export AWS_PROFILE=selected AWS_DEFAULT_PROFILE=ignored PROFILE=ignored ;;
            default) export AWS_DEFAULT_PROFILE=selected PROFILE=ignored ;;
            legacy) export PROFILE=selected SSO_CONFIG=legacy ;;
        esac
        if [ "$source" = cli ]; then
            output="$(run_events --profile selected check_seats --event-id "$EVENT_ID" 2>"$TEST_DIR/sso-stderr")" || {
                fail_test "expired SSO check failed: $(cat "$TEST_DIR/sso-stderr")"
            }
        else
            output="$(run_events check_seats --event-id "$EVENT_ID" 2>"$TEST_DIR/sso-stderr")" || {
                fail_test "expired SSO check failed: $(cat "$TEST_DIR/sso-stderr")"
            }
        fi
        printf '%s' "$output" | jq -se 'length == 1 and .[0].state == "COMPLETED"' >/dev/null
        calls="$(cat "$AWS_CALLS")"
        contains "$calls" 'sso login'
        contains "$(cat "$TEST_DIR/sso-stderr")" 'fixture SSO sign-in instructions'
        flow="$(sed -n -e '/configure export-credentials/s/.*/export/p' -e '/sso login/s/.*/login/p' "$AWS_CALLS")"
        [ "$flow" = "$(printf 'export\nlogin\nexport')" ] || fail_test 'SSO recovery did not retry export exactly once'
        if [ "$source" = cli ]; then
            contains "$calls" 'sso login --profile selected'
        else
            case "$calls" in *--profile*) fail_test 'SSO recovery forced an inherited profile' ;; esac
        fi
        if [ "$source" = chain ]; then contains "$calls" 'profile= region=ca-central-1'
        else contains "$calls" 'profile=selected region=ca-central-1'; fi
    )
done

# Login and retry failures stop before HTTP, without leaking credentials or looping.
for fault in 'SSO_CONFIG=none' 'LOGIN_FAILURE=true' 'EXPORT_FAILURE=true'; do
    : >"$AWS_CALLS"
    : >"$HTTP_CALLS"
    rm -f "$SSO_MARKER"
    if output="$(env EXPIRED_SSO=true SSO_CONFIG=modern "$fault" bash "$TEST_DIR/repo/events.sh" \
        --profile selected check_seats --event-id "$EVENT_ID" 2>&1)"; then fail_test "accepted $fault"
    else [ "$?" -eq 2 ] || fail_test "wrong exit code for $fault"; fi
    [ ! -s "$HTTP_CALLS" ] || fail_test 'failed SSO recovery contacted HTTP endpoints'
    case "$output" in *v4.public.fixture*|*fixture-secret*) fail_test 'SSO recovery disclosed credentials' ;; esac
    flow="$(sed -n -e '/configure export-credentials/s/.*/export/p' -e '/sso login/s/.*/login/p' "$AWS_CALLS")"
    case "$fault" in
        SSO_CONFIG=none) expected_flow=export; contains "$output" 'AWS credential export failed' ;;
        LOGIN_FAILURE=true) expected_flow="$(printf 'export\nlogin')"; contains "$output" 'AWS SSO login failed' ;;
        EXPORT_FAILURE=true) expected_flow="$(printf 'export\nlogin\nexport')"; contains "$output" 'AWS credential export failed after SSO login' ;;
    esac
    [ "$flow" = "$expected_flow" ] || fail_test "unexpected SSO recovery flow for $fault"
done

# The authenticated intake supplies the tenant; the wrapper does not decode token claims.
for tenant in another-owner 'é-tenant' $' tenant\n'; do
    for command_name in check_seats reserve_seat; do
        command_args=("$command_name" --event-id "$EVENT_ID")
        if [ "$command_name" = reserve_seat ]; then command_args+=(--class general --quantity 2); fi
        output="$(SUBMITTED_READS=0 RESPONSE_TENANT="$tenant" run_events "${command_args[@]}")"
        printf '%s' "$output" | jq -e --arg tenant "$tenant" '.tenant == $tenant' >/dev/null
    done
done

# Invalid endpoint discovery fails before intake; transport and identity errors stop polling.
for command_name in check_seats reserve_seat; do
    command_args=("$command_name" --event-id "$EVENT_ID")
    if [ "$command_name" = reserve_seat ]; then command_args+=(--class general --quantity 2); fi
    for endpoint in INTAKE_URL QUERY_URL; do
        : >"$HTTP_CALLS"
        if output="$(env "$endpoint=http://invalid/" bash "$TEST_DIR/repo/events.sh" \
            "${command_args[@]}" 2>&1)"; then fail_test 'accepted invalid endpoint'; fi
        [ ! -s "$HTTP_CALLS" ] || fail_test 'invalid endpoint submitted work'
    done
    for fault in 'CURL_FAILURE=true' 'BAD_RESPONSE=true' 'HTTP_STATUS=401' 'RESPONSE_TENANT=' \
        "RESPONSE_TENANT=$(printf '%065d' 0)" \
        'QUERY_CURL_FAILURE=true' 'BAD_QUERY_RESPONSE=true' 'QUERY_HTTP_STATUS=401' 'QUERY_TENANT=foreign' \
        'EXTRA_QUERY_RESPONSE=true' 'MISSING_RESULT=true' 'RESULT_TYPE=INVALID' \
        'QUERY_OPERATION_ID=foreign' 'QUERY_OPERATION_NAME=foreign'; do
        : >"$SLEEP_CALLS"
        if output="$(env "$fault" SUBMITTED_READS=0 bash "$TEST_DIR/repo/events.sh" \
            "${command_args[@]}" 2>&1)"; then fail_test "accepted $fault"
        else [ "$?" -eq 2 ] || fail_test "wrong exit code for $fault"; fi
        contains "$output" "$(jq -r .id "$REQUEST_FILE")"
        [ ! -s "$SLEEP_CALLS" ] || fail_test "$command_name retried a failed request"
        case "$output" in *v4.public.fixture*|*fixture-secret*) fail_test 'failure disclosed credentials' ;; esac
    done
done

cat >"$TEST_DIR/repo/zig-out/bin/events" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 5 ] && [ "$1" = read ] && [ "$2" = --tenant ] &&
    [ "$3" = "${EXPECTED_TENANT:-fixture-owner}" ] && [ "$4" = --event-id ] &&
    [ "$5" = "$EVENT_ID" ] || exit 90
[ "$EVENTS_TABLE_NAME" = fixture-events ] || exit 91
[ "$AWS_ACCESS_KEY_ID" = fixture-access ] && [ "$AWS_SECRET_ACCESS_KEY" = fixture-secret ] || exit 92
if [ "${STATIC_CREDENTIALS:-false}" = true ]; then
    [ -z "${AWS_SESSION_TOKEN:-}" ] || exit 93
else
    [ "$AWS_SESSION_TOKEN" = fixture-session ] || exit 94
fi
[ -z "${PASETO_TOKEN:-}${PASETO_PRIVATE_KEY:-}" ] || exit 95
printf '{"state":"ready"}\n'
MOCK
chmod +x "$TEST_DIR/repo/zig-out/bin/events"

# Reads require an explicit tenant even when a token contains a usable subject.
token_with_subject="v4.public.$(jq -nr '{sub:"token-owner"} | tojson + ("0" * 64) |
    @base64 | gsub("[+]";"-") | gsub("/";"_") | sub("=+$";"")')"
for token in '' malformed "$token_with_subject"; do
    PASETO_TOKEN="$token" reject read --event-id "$EVENT_ID"
    contains "$(cat "$TEST_DIR/output")" 'read requires --tenant and --event-id'
    PASETO_TOKEN="$token" EXPECTED_TENANT=explicit-owner \
        run_events read --event-id "$EVENT_ID" --tenant explicit-owner >/dev/null
done
reject read --tenant explicit-owner
reject read --tenant= --event-id "$EVENT_ID"
# Explicit tenant arguments preserve exact Unicode and whitespace.
for tenant in 'é-tenant' $' tenant\n'; do
    EXPECTED_TENANT="$tenant" run_events read --tenant "$tenant" --event-id "$EVENT_ID" >/dev/null
done

# Environment selectors follow the scenario runner's precedence without forcing --profile.
for source in aws default legacy; do
    : >"$AWS_CALLS"
    (
        export PROFILE=legacy REGION=legacy-region EXPECTED_REGION=legacy-region
        case "$source" in
            aws) export AWS_PROFILE=selected AWS_DEFAULT_PROFILE=ignored AWS_REGION=selected-region
                 export AWS_DEFAULT_REGION=ignored EXPECTED_REGION=selected-region ;;
            default) export AWS_DEFAULT_PROFILE=selected AWS_DEFAULT_REGION=selected-region
                     export EXPECTED_REGION=selected-region ;;
        esac
        export AWS_ACCESS_KEY_ID=inherited AWS_SECRET_ACCESS_KEY=inherited-secret AWS_SESSION_TOKEN=old-session
        export EXPECTED_ACCESS_KEY=inherited EXPECTED_SESSION_TOKEN=old-session
        run_events read --tenant fixture-owner --event-id "$EVENT_ID" >/dev/null
    )
    calls="$(cat "$AWS_CALLS")"
    if [ "$source" = legacy ]; then contains "$calls" 'profile=legacy region=legacy-region'
    else contains "$calls" 'profile=selected region=selected-region'; fi
    case "$calls" in *--profile*) fail_test 'inherited profile overrode environment credentials' ;; esac
done

: >"$AWS_CALLS"
AWS_PROFILE=ignored AWS_REGION=ignored EXPECTED_REGION=cli-region STATIC_CREDENTIALS=true \
    run_events --profile=cli-profile --region cli-region --stack-name cli-stack \
    read --tenant=fixture-owner --event-id="$EVENT_ID" >/dev/null
calls="$(cat "$AWS_CALLS")"
contains "$calls" '--profile cli-profile'
contains "$calls" '--stack-name cli-stack'
contains "$calls" 'profile=cli-profile region=cli-region'

for fault in BAD_CREDENTIALS CURL_FAILURE BAD_RESPONSE; do
    if output="$(env "$fault=true" bash "$TEST_DIR/repo/events.sh" create \
        --class general=3 --event-id "$EVENT_ID" 2>&1)"; then fail_test "accepted $fault"; fi
    case "$output" in *v4.public.fixture*|*fixture-secret*) fail_test 'failure disclosed credentials' ;; esac
done
if output="$(HTTP_STATUS=401 run_events create --class general=3 --event-id "$EVENT_ID" 2>&1)"; then
    fail_test 'accepted rejected token'
fi
contains "$output" 'HTTP 401'
printf 'PASS: Events wrapper regression tests\n'
