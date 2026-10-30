#!/usr/bin/env bash
# Deployed Seat Reservation scenarios; never builds or deploys.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: seat_scenarios.sh [options]

Exercise an existing development stack; retain sanitized evidence in a new directory.
Creates a Seat Event, reserves seats, and confirms them in the selected stack.
Uses the existing AWS credential chain and the PASETO_TOKEN environment variable.
Optional PASETO_FOREIGN_TOKEN enables cross-tenant checks (a different subject).
Requires Bash 3.2+, jq 1.6+, AWS CLI, curl, and prebuilt
zig-out/bin/{events,dynamodb,ledger-counter} utilities.

Options:
  --profile PROFILE      Override AWS profile (otherwise AWS_PROFILE,
                         AWS_DEFAULT_PROFILE, PROFILE, or the AWS CLI default)
  --region REGION        Override AWS_REGION, AWS_DEFAULT_REGION, REGION
                         (default: ca-central-1)
  --stack-name STACK     Override STACK_NAME (default: aws-lambda-zig-demo)
  --output-dir DIRECTORY Override OUTPUT_DIR; must be new with an existing parent
                         (default: a new .scratch/seat-scenarios.XXXXXX directory)
  --poll-attempts N      1-60 reads per Operation (default: 30)
  --poll-seconds N       0-5 seconds between reads (default: 2; fractions allowed)
  --timeout-seconds N    1-300 seconds for the entire run (default: 300; fractions allowed)
  --authorize-cloud      Accepted for compatibility; no longer required
  -h, --help             Show help without executing utilities or contacting AWS
USAGE
}

argument_error() { printf 'seat scenarios: %s\n\n' "$1" >&2; usage >&2; exit 2; }
profile="${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-${PROFILE:-}}}"
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-${REGION:-ca-central-1}}}"
stack_name="${STACK_NAME:-aws-lambda-zig-demo}"
output_dir="${OUTPUT_DIR:-}"
explicit_profile=false
poll_attempts=30 poll_seconds=2 timeout_seconds=300
while [ "$#" -gt 0 ]; do
    option="$1"
    case "$option" in
        -h|--help) usage; exit 0 ;;
        --authorize-cloud) shift; continue ;;
        --profile|--region|--stack-name|--output-dir|--poll-attempts|--poll-seconds|--timeout-seconds)
            [ "$#" -ge 2 ] && [[ "$2" != --* && "$2" != -h ]] ||
                argument_error 'missing option value'
            value="$2"; shift 2 ;;
        --profile=*|--region=*|--stack-name=*|--output-dir=*|--poll-attempts=*|--poll-seconds=*|--timeout-seconds=*)
            value="${option#*=}"; option="${option%%=*}"; shift ;;
        *) argument_error 'invalid invocation' ;;
    esac
    [ -n "$value" ] || argument_error 'option values must be nonempty'
    case "$option" in
        --profile) profile="$value"; explicit_profile=true ;;
        --region) region="$value" ;;
        --stack-name) stack_name="$value" ;;
        --output-dir) output_dir="$value" ;;
        --poll-attempts) poll_attempts="$value" ;;
        --poll-seconds) poll_seconds="$value" ;;
        --timeout-seconds) timeout_seconds="$value" ;;
    esac
done
[[ -z "$profile" || "$profile" =~ [^[:space:]] ]] &&
    [[ "$region" =~ [^[:space:]] && "$stack_name" =~ [^[:space:]] ]] ||
    argument_error 'invalid profile, region or stack name'
owner_token="${PASETO_TOKEN:-}"
foreign_token="${PASETO_FOREIGN_TOKEN:-}"
unset PASETO_TOKEN PASETO_FOREIGN_TOKEN PASETO_PRIVATE_KEY
[[ "$owner_token" =~ ^v4\.public\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?$ &&
    "${#owner_token}" -le 16384 ]] || argument_error 'PASETO_TOKEN must be a v4.public token'
if [ -n "$foreign_token" ]; then
    [[ "$foreign_token" =~ ^v4\.public\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?$ &&
        "${#foreign_token}" -le 16384 && "$foreign_token" != "$owner_token" ]] ||
        argument_error 'PASETO_FOREIGN_TOKEN must be a different v4.public token'
fi
command -v jq >/dev/null 2>&1 || argument_error 'missing command: jq'
[[ "$poll_attempts" =~ ^[0-9]+$ ]] &&
    jq -en --arg n "$poll_attempts" '$n | tonumber | . >= 1 and . <= 60' >/dev/null 2>&1 ||
    argument_error 'poll bounds: attempts 1-60, seconds 0-5'
for value in "$poll_seconds" "$timeout_seconds"; do
    [[ "$value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]] ||
        argument_error 'invalid seconds value'
done
jq -en --arg p "$poll_seconds" --arg t "$timeout_seconds" \
    '($p|tonumber) >= 0 and ($p|tonumber) <= 5 and ($t|tonumber) >= 1 and ($t|tonumber) <= 300' \
    >/dev/null 2>&1 || argument_error 'poll seconds must be 0-5 and timeout seconds 1-300'
# Normalize numbers for Bash arithmetic and sleep (including exponent notation).
poll_attempts="$(jq -nr --arg n "$poll_attempts" '$n|tonumber')"
poll_seconds="$(jq -nr --arg n "$poll_seconds" '$n|tonumber')"
timeout_seconds="$(jq -nr --arg n "$timeout_seconds" '$n|tonumber')"

umask 077
if [ -z "$output_dir" ]; then
    mkdir -p .scratch
    output_dir="$(mktemp -d .scratch/seat-scenarios.XXXXXX)"
else
    mkdir -m 700 -- "$output_dir" 2>/dev/null ||
        argument_error 'output directory must be new and have an existing parent'
fi
printf 'Seat scenario evidence: %s\n' "$output_dir"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage=prerequisites reason='invalid output or local I/O failure'
manifest='{"evidence":"deployed","status":"running","operations":{}}'
work_dir= command_pid= command_timer= deadline_timer=
fail() { reason="$1"; exit 1; }
stop_group() {
    [ -z "$1" ] || kill -KILL -- "-$1" 2>/dev/null || :
}
save() { printf '%s\n' "$2" | jq . >"$output_dir/$1.json" 2>/dev/null; }
finish() {
    local status=$?
    trap - EXIT INT TERM
    stop_group "$command_pid"
    stop_group "$command_timer"
    stop_group "$deadline_timer"
    if [ "$status" -ne 0 ]; then
        manifest="$(printf '%s' "$manifest" | jq --arg stage "$stage" --arg reason "$reason" \
            '. + {status:"failed",stage:$stage,reason:$reason}' 2>/dev/null)" || :
        save manifest "$manifest" || :
        printf 'seat scenarios: %s: %s\n' "$stage" "$reason" >&2
    fi
    [ -z "$work_dir" ] || rm -rf -- "$work_dir"
    exit "$status"
}
trap finish EXIT
trap 'fail "scenario deadline exceeded or invocation interrupted"' TERM INT
# Each background job owns a process group, so timeouts also stop descendants.
set -m
runner_pid=$$
(sleep "$timeout_seconds"; kill -TERM "$runner_pid" 2>/dev/null) &
deadline_timer=$!
save manifest "$manifest"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/seat-scenarios.XXXXXX")"

# jq normally accepts duplicate object fields. Validate the stream before decoding,
# including repeated container keys, and accept exactly one complete JSON value.
cat >"$work_dir/decode.jq" <<'JQ'
reduce inputs as $item (
    {seen:{}, active:[], closed:false, events:[]};
    if .closed then error("multiple JSON values") else . end
    | .events += [$item]
    | $item[0] as $path
    | if ($item|length) == 2 then
        reduce range(1; ($path|length) + 1) as $n (.;
            ($path[0:$n]) as $prefix
            | if $n <= (.active|length) and $prefix == .active[0:$n] then .
              elif .seen[$prefix|tojson] then error("duplicate JSON field")
              else .seen[$prefix|tojson] = true end)
        | .active = $path[0:-1]
        | .closed = (($path|length) == 0)
      else
        .active = $path[0:-2]
        | .closed = (($path|length) == 1)
      end
) | if .closed then fromstream(.events[]) else error("incomplete JSON") end
JQ
jq_helpers='
def fields($names): type == "object" and keys == ($names|sort);
def uint: type == "number" and . >= 0 and floor == .;
def native_id:
    type == "string" and test("^[1-9][0-9]{0,38}$") and
    (length < 39 or . <= "340282366920938463463374607431768211454");
'
parse_json() {
    # Reject jq's permissive numeric extensions (NaN, Inf, leading zeroes, etc.).
    # jq itself checks structure and escapes after strings are masked here.
    printf '%s' "$RESPONSE" | jq -Rse '
        gsub("\"([^\"\\\\]|\\\\.)*\""; "\"\"") |
        test("^([\\[\\]{},: \\t\\r\\n]|\"\"|true|false|null|-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?(?![0-9.eE+-]))*$")
    ' >/dev/null 2>&1 || fail 'invalid JSON output'
    JSON="$(printf '%s' "$RESPONSE" | jq --stream -cn -f "$work_dir/decode.jq" 2>/dev/null)" ||
        fail 'invalid JSON output'
}
check_json() {
    local filter="$1" message="$2"
    shift 2
    printf '%s' "$JSON" | jq -e "$@" "$jq_helpers $filter" >/dev/null 2>&1 || fail "$message"
}
exact() {
    check_json '. == $expected' 'unexpected public Result' --argjson expected "$1"
}
command_run() {
    local tool="$1" executable="$1" status=0 bytes
    shift
    case "$tool" in
        events|dynamodb|ledger-counter) executable="$root/zig-out/bin/$tool" ;;
    esac
    (
        case "$tool" in
            events|dynamodb|ledger-counter)
                # The pinned SDK prioritizes profile endpoint_url over its ignore flag.
                export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null ;;
        esac
        exec "$executable" "$@"
    ) <"$work_dir/input" >"$work_dir/stdout" 2>"$work_dir/stderr" &
    command_pid=$!
    (sleep 30; : >"$work_dir/timed-out"; stop_group "$command_pid") &
    command_timer=$!
    wait "$command_pid" 2>/dev/null || status=$?
    stop_group "$command_timer"
    wait "$command_timer" 2>/dev/null || :
    command_timer=
    stop_group "$command_pid"
    command_pid=
    [ ! -f "$work_dir/timed-out" ] || fail "$tool timed out"
    [ "$status" -eq 0 ] || fail "$tool failed (exit $status)"
    bytes="$(wc -c <"$work_dir/stdout")"
    [ "$bytes" -le 131072 ] || fail "$tool output exceeds bound"
    RESPONSE="$(cat "$work_dir/stdout")"
    RESPONSE="${RESPONSE#"${RESPONSE%%[!$' \t\r\n']*}"}"
    RESPONSE="${RESPONSE%"${RESPONSE##*[!$' \t\r\n']}"}"
}
aws_run() {
    if [ "$explicit_profile" = true ]; then
        command_run aws "$@" --profile "$profile" --no-cli-pager \
            --cli-connect-timeout 5 --cli-read-timeout 10
    else
        command_run aws "$@" --no-cli-pager --cli-connect-timeout 5 --cli-read-timeout 10
    fi
}
new_uuid() {
    local hex variant
    hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    [ "${#hex}" -eq 32 ] || fail 'could not generate Operation UUID'
    variant="$(printf '%x' "$(( (16#${hex:16:1} & 3) | 8 ))")"
    UUID="${hex:0:8}-${hex:8:4}-4${hex:13:3}-$variant${hex:17:3}-${hex:20:12}"
}

for tool in aws curl; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing command: $tool"
done
for tool in events dynamodb ledger-counter; do
    [ -x "$root/zig-out/bin/$tool" ] || fail "missing prebuilt host utility: $tool"
done
while IFS= read -r key; do
    [ -z "${!key}" ] || fail 'AWS endpoint overrides are not allowed'
done < <(compgen -e | sed -n '/^AWS_ENDPOINT_URL/p')
# Preserve inherited credentials while the AWS CLI resolves its credential chain.
[ -z "$profile" ] || export AWS_PROFILE="$profile"
unset AWS_DEFAULT_PROFILE
export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"
export AWS_EC2_METADATA_DISABLED=true AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true AWS_MAX_ATTEMPTS=1
: >"$work_dir/input"
stage='credential export'
aws_run configure export-credentials --format process
parse_json
check_json 'type == "object" and all(.AccessKeyId,.SecretAccessKey; type == "string" and length > 0) and
    (.SessionToken == null or (.SessionToken|type == "string"))' 'credential export omitted credentials'
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
export AWS_ACCESS_KEY_ID="$(printf '%s' "$JSON" | jq -r .AccessKeyId)"
export AWS_SECRET_ACCESS_KEY="$(printf '%s' "$JSON" | jq -r .SecretAccessKey)"
session_token="$(printf '%s' "$JSON" | jq -r '.SessionToken // empty')"
[ -z "$session_token" ] || export AWS_SESSION_TOKEN="$session_token"
unset session_token
stage='stack discovery'
aws_run cloudformation describe-stacks --stack-name "$stack_name" --region "$region" --output json
parse_json
check_json 'type == "object" and (.Stacks|type == "array" and length == 1)' 'expected one deployed stack'
check_json '(.Stacks[0].Outputs // []) | type == "array" and
    all(.[]; type == "object" and (.OutputKey|type == "string") and (.OutputValue|type == "string")) and
    ([.[].OutputKey]|length == (unique|length))' 'invalid or duplicate stack output'
binding="$(printf '%s' "$JSON" | jq -c '.Stacks[0].Outputs | map({key:.OutputKey,value:.OutputValue}) | from_entries')"
JSON="$binding"
for key in IntakeFunctionUrl QueryFunctionUrl; do
    check_json '.[$key] | type == "string" and test("^https://(\\[[0-9a-fA-F:.]+\\]|[^/?#@:[:space:]]+)(:[0-9]+)?/?$")' \
        "missing or invalid $key output" --arg key "$key"
done
intake_url="$(printf '%s' "$binding" | jq -r .IntakeFunctionUrl)"
query_url="$(printf '%s' "$binding" | jq -r .QueryFunctionUrl)"
for key in SeatEventsTableName LedgerCounterTableName; do
    check_json '.[$key] | type == "string" and test("^[A-Za-z0-9_.-]{3,255}$")' \
        "missing or invalid $key output" --arg key "$key"
done
check_json '.LedgerCounterId | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")' \
    'missing or invalid LedgerCounterId output; deploy the six-function baseline'
export EVENTS_TABLE_NAME="$(printf '%s' "$binding" | jq -r .SeatEventsTableName)"
export LEDGER_COUNTER_TABLE_NAME="$(printf '%s' "$binding" | jq -r .LedgerCounterTableName)"
counter_id="$(printf '%s' "$binding" | jq -r .LedgerCounterId)"
aws_run cloudformation describe-stack-resource --stack-name "$stack_name" --region "$region" \
    --logical-resource-id OperationsTable --output json
parse_json
check_json '.StackResourceDetail.PhysicalResourceId | type == "string" and test("^[A-Za-z0-9_.-]{3,255}$")' \
    'missing or invalid OperationsTable physical resource'
export OPERATIONS_TABLE_NAME="$(printf '%s' "$JSON" | jq -r .StackResourceDetail.PhysicalResourceId)"

http() {
    local method="$1" url="$2" token="${3:-}" body="${4:-}" expected_status="${5:-200}" code
    {
        printf 'url = %s\n' "$(printf '%s' "$url" | jq -Rs .)"
        printf 'request = "%s"\nsilent\nshow-error\nconnect-timeout = 5\nmax-time = 10\n' "$method"
        printf 'max-filesize = 65536\nproto = "=https"\nwrite-out = "\\n%%{http_code}"\n'
        if [ -n "$token" ]; then
            printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "$token" | jq -Rs .)"
        fi
        if [ -n "$body" ]; then
            printf 'header = "Content-Type: application/json"\ndata = %s\n' "$(printf '%s' "$body" | jq -Rs .)"
        fi
    } >"$work_dir/input"
    command_run curl --disable --config -
    : >"$work_dir/input"
    [[ "$RESPONSE" == *$'\n'* ]] || fail 'invalid HTTP status output'
    code="${RESPONSE##*$'\n'}"
    [[ "$code" =~ ^[0-9]{3}$ ]] || fail 'invalid HTTP status output'
    [ "$code" = "$expected_status" ] || fail "unexpected HTTP status $code (expected $expected_status)"
    RESPONSE="${RESPONSE%$'\n'*}"
}
operation() {
    check_json 'type == "object" and (.state == "SUBMITTED" or .state == "COMPLETED") and
        fields(["id","tenant","name","state","hash","last_updated","expires_at"] +
            (if .state == "COMPLETED" then ["result"] else [] end)) and
        .id == $id and .tenant == $tenant and .name == "SeatReservation" and
        (.hash | type == "string" and test("^[a-f0-9]{64}$")) and
        (.last_updated|uint) and (.expires_at|uint)' \
        'Operation identity, fields or metadata mismatch' --arg id "$operation_id" --arg tenant "$tenant"
}
submit() {
    local label="$1" body="$2" tenant="$3" token="$4" payload="${5:-null}" result_type="${6:-SUCCESS}"
    local operation_id request attempt completed expected
    new_uuid; operation_id="$UUID"
    manifest="$(printf '%s' "$manifest" | jq --arg label "$label" --arg id "$operation_id" '.operations[$label] = $id')"
    save manifest "$manifest"
    stage="$label intake (Operation $operation_id)"
    request="$(jq -cn --arg id "$operation_id" --argjson body "$body" '{id:$id,name:"SeatReservation",body:$body}')"
    http POST "$intake_url" "$token" "$request"
    parse_json
    if [ -z "$tenant" ]; then
        # The authenticated handler supplies the subject; never decode unverified claims.
        check_json '.tenant | type == "string" and (utf8bytelength >= 1 and utf8bytelength <= 64)' \
            'invalid authenticated tenant'
        tenant="$(printf '%s' "$JSON" | jq -r .tenant)"
        case "$label" in
            create) owner="$tenant" ;;
            foreign_check)
                [ "$tenant" != "$owner" ] || fail 'tenant tokens have the same subject'
                foreign_tenant="$tenant" ;;
        esac
        manifest="$(printf '%s' "$manifest" | jq --arg tenant "$tenant" '.tenants += [$tenant]')"
        save manifest "$manifest"
    fi
    operation
    stage="$label query (Operation $operation_id)"
    for ((attempt=0; attempt<poll_attempts; attempt++)); do
        http GET "${query_url%/}/$operation_id" "$token"
        parse_json; operation
        if [ "$(printf '%s' "$JSON" | jq -r .state)" = COMPLETED ]; then
            completed="$JSON"
            case "$label" in
                create) payload="$(jq -cn --arg id "$operation_id" '{event_id:$id}')" ;;
                reserve)
                    check_json '.result.payload.reservation_id | native_id' 'invalid reservation ID'
                    payload="$(printf '%s' "$JSON" | jq -c --argjson payload "$payload" \
                        '$payload + {reservation_id:.result.payload.reservation_id}')" ;;
            esac
            expected="$(jq -cn --arg type "$result_type" --argjson payload "$payload" '{type:$type,payload:$payload}')"
            JSON="$(printf '%s' "$completed" | jq -c .result)"
            exact "$expected"
            save "$label" "$completed"
            stage="$label persistent Operation inspection"
            command_run dynamodb read --id "$operation_id"
            parse_json; exact "$completed"
            OPERATION="$completed"
            return
        fi
        if [ "$((attempt + 1))" -lt "$poll_attempts" ]; then
            # Use the same cancellable command path for polling delays.
            command_run sleep "$poll_seconds"
        fi
    done
    fail "Operation polling timed out after $poll_attempts attempts"
}
counter() {
    local label="$1"
    stage="$label counter inspection"
    command_run ledger-counter --counter-id "$counter_id" read
    parse_json
    check_json 'fields(["counter_id","high_water"]) and .counter_id == $id and
        (.high_water|uint and . >= 1000 and . <= 4294967295)' \
        'invalid selected counter output' --arg id "$counter_id"
    save "${label}_counter" "$JSON"
    HIGH_WATER="$(printf '%s' "$JSON" | jq -r .high_water)"
}

owner= foreign_tenant=
manifest="$(printf '%s' "$manifest" | jq '. + {tenants:[],tenant_isolation:"skipped"}')"
if [ -n "$foreign_token" ]; then
    manifest="$(printf '%s' "$manifest" | jq '.tenant_isolation = "pending"')"
fi
save manifest "$manifest"
stage='unauthenticated public requests'
http POST "$intake_url" '' '{}' 401
new_uuid; http GET "${query_url%/}/$UUID" '' '' 401
counter before; before="$HIGH_WATER"
submit create '{"command":"create_event","classes":{"general":3,"premium":2},"timeout_seconds":300}' "$owner" "$owner_token"
event_id="$(printf '%s' "$OPERATION" | jq -r .id)"
stage='persistent Event inspection'
command_run events read --tenant "$owner" --event-id "$event_id"
parse_json
check_json 'fields(["tenant","event_id","ledger","timeout_seconds","capacity_account_id","allocation_account_id","state","classes"]) and
    .tenant == $tenant and .event_id == $event and .state == "ready" and .timeout_seconds == 300 and
    (.ledger|uint and . > $before and . <= 4294967295) and
    (.capacity_account_id|native_id) and (.allocation_account_id|native_id) and
    (.classes|fields(["general","premium"])) and
    all(.classes[]; fields(["total","tb_account_id"]) and (.total|uint) and (.tb_account_id|native_id)) and
    .classes.general.total == 3 and .classes.premium.total == 2' \
    'Event identity, readiness, ledger or class configuration mismatch' \
    --arg tenant "$owner" --arg event "$event_id" --argjson before "$before"
save event "$JSON"
ledger="$(printf '%s' "$JSON" | jq -r .ledger)"
counter after
[ "$HIGH_WATER" -ge "$ledger" ] || fail 'counter does not cover Event ledger'
check_body="$(jq -cn --arg id "$event_id" '{command:"check_seats",event_id:$id}')"
check_payload="$(jq -cn --arg id "$event_id" '{event_id:$id,classes:{general:{total:3,available:3},premium:{total:2,available:2}}}')"
submit initial_check "$check_body" "$owner" "$owner_token" "$check_payload"
reserve_body="$(jq -cn --arg id "$event_id" '{command:"reserve_seats",event_id:$id,class:"general",quantity:2}')"
reserve_payload="$(jq -cn --arg id "$event_id" '{event_id:$id,class:"general",quantity:2}')"
submit reserve "$reserve_body" "$owner" "$owner_token" "$reserve_payload"
pending_id="$(printf '%s' "$OPERATION" | jq -r .result.payload.reservation_id)"
check_payload="$(printf '%s' "$check_payload" | jq -c '.classes.general.available = 1')"
submit held_check "$check_body" "$owner" "$owner_token" "$check_payload"
confirm_body="$(jq -cn --arg id "$event_id" --arg pending "$pending_id" \
    '{command:"confirm_seats",event_id:$id,class:"general",pending_id:$pending}')"
confirm_payload="$(jq -cn --arg id "$event_id" --arg pending "$pending_id" \
    '{event_id:$id,class:"general",reservation_id:$pending}')"
submit confirm "$confirm_body" "$owner" "$owner_token" "$confirm_payload"
submit final_check "$check_body" "$owner" "$owner_token" "$check_payload"
if [ -n "$foreign_token" ]; then
    stage='tenant isolation through public query and intake'
    http GET "${query_url%/}/$event_id" "$foreign_token" '' 404
    foreign_response="$RESPONSE"
    new_uuid; http GET "${query_url%/}/$UUID" "$foreign_token" '' 404
    [[ "$foreign_response" = $'Not Found\n' && "$RESPONSE" = "$foreign_response" ]] ||
        fail 'cross-tenant query disclosed Operation data'
    request="$(jq -cn --arg id "$event_id" --argjson body "$check_body" '{id:$id,name:"SeatReservation",body:$body}')"
    http POST "$intake_url" "$foreign_token" "$request" 409
    submit foreign_check "$check_body" "$foreign_tenant" "$foreign_token" '{"code":"event_unavailable"}' FAILURE
    submit foreign_reserve "$reserve_body" "$foreign_tenant" "$foreign_token" '{"code":"event_unavailable"}' FAILURE
    submit foreign_confirm "$confirm_body" "$foreign_tenant" "$foreign_token" '{"code":"event_unavailable"}' FAILURE
    manifest="$(printf '%s' "$manifest" | jq '.tenant_isolation = "passed"')"
else
    printf 'Tenant isolation checks skipped; set PASETO_FOREIGN_TOKEN to enable them.\n'
fi
manifest="$(printf '%s' "$manifest" | jq '.status = "passed"')"
save manifest "$manifest"
printf 'Deployed seat scenarios passed; sanitized evidence retained in %s.\n' "$output_dir"
