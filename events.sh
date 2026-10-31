#!/usr/bin/env bash
set -euo pipefail

profile="${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-${PROFILE:-}}}"
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-${REGION:-ca-central-1}}}"
stack_name="${STACK_NAME:-aws-lambda-zig-demo}"
explicit_profile=false

fail() { printf 'events: %s\n' "$1" >&2; exit 2; }
new_uuid() {
    local hex variant
    hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    [ "${#hex}" -eq 32 ] || fail 'could not generate Operation UUID'
    variant="$(printf '%x' "$(( (16#${hex:16:1} & 3) | 8 ))")"
    printf '%s\n' "${hex:0:8}-${hex:8:4}-4${hex:13:3}-$variant${hex:17:3}-${hex:20:12}"
}
usage() {
    cat <<'USAGE'
Usage:
  events.sh [--profile PROFILE] [--region REGION] [--stack-name STACK] <command>
  events.sh create --class TAG=COUNT [--class TAG=COUNT ...]
                   [--timeout-seconds SECONDS] [--event-id UUID]
  events.sh read --tenant TENANT --event-id UUID
  events.sh check_seats --event-id UUID
  events.sh reserve_seat --event-id UUID --class TAG --quantity COUNT

Create requires explicit seat classes and counts and PASETO_TOKEN; no stdin JSON.
It submits an authenticated SeatReservation create_event Operation to the stack's
IntakeFunctionUrl. The verified token supplies the tenant; processors allocate
the ledger and native IDs. Output is the submitted Operation, not readiness evidence.
Use --event-id to retry the same creation; otherwise a fresh UUID is generated.
Reservation timeout defaults to 300 seconds. Counts and timeout are positive u32.
Read returns persisted Event metadata using the prebuilt zig-out/bin/events utility.
Read requires explicit --tenant and --event-id; AWS credentials authorize metadata reads.
The check_seats command requires --event-id and PASETO_TOKEN, which supplies the tenant.
Any --tenant value supplied to check_seats is ignored.
The reserve_seat command requires --event-id, one --class tag, a positive u32 --quantity,
and PASETO_TOKEN. It submits reserve_seats and creates a timed hold without confirmation.
Tenant overrides are rejected for reserve_seat; the verified token supplies the tenant.
Both commands submit a fresh Operation, then query every second until COMPLETED,
with no overall polling limit and no host binary required.
Each query prints its Operation; the final one includes its SUCCESS or FAILURE result.
Either terminal result exits 0. Uncertain requests are not automatically resubmitted.
HTTP/configuration errors exit 2 and report the Operation UUID when available.

Options override the environment. Profile: AWS_PROFILE, AWS_DEFAULT_PROFILE,
PROFILE, or the AWS CLI default credential chain. Region: AWS_REGION,
AWS_DEFAULT_REGION, REGION, or ca-central-1. STACK_NAME defaults to aws-lambda-zig-demo.
An inherited profile preserves environment credentials; --profile explicitly selects it.
Failed credential export for an SSO profile triggers one SSO login and export retry.
Complete browser sign-in if prompted; login instructions go to stderr.
USAGE
}

while [ "$#" -gt 0 ]; do
    option="$1"
    case "$option" in
        --help|-h|help) usage; exit 0 ;;
        --profile|--region|--stack-name)
            [ "$#" -ge 2 ] && [[ "$2" != --* && "$2" != -h ]] ||
                fail 'missing wrapper option value'
            value="$2"; shift 2 ;;
        --profile=*|--region=*|--stack-name=*)
            value="${option#*=}"; option="${option%%=*}"; shift ;;
        create|read|check_seats|reserve_seat) break ;;
        *) fail 'invalid invocation; use --help' ;;
    esac
    [ -n "$value" ] || fail 'wrapper option values must be nonempty'
    case "$option" in
        --profile) profile="$value"; explicit_profile=true ;;
        --region) region="$value" ;;
        --stack-name) stack_name="$value" ;;
    esac
done
[ "$#" -gt 0 ] || fail 'missing command; use --help'
command_name="$1"; shift
if [ "$#" -eq 1 ]; then
    case "$1" in --help|-h|help) usage; exit 0 ;; esac
fi
[[ -z "$profile" || "$profile" =~ [^[:space:]] ]] &&
    [[ "$region" =~ [^[:space:]] && "$stack_name" =~ [^[:space:]] ]] ||
    fail 'invalid wrapper configuration'
command -v jq >/dev/null 2>&1 || fail 'missing required command: jq'

event_id= tenant= timeout_seconds=300 classes='{}' class_count=0 seat_class= quantity=
while [ "$#" -gt 0 ]; do
    option="$1"
    case "$option" in
        --event-id|--tenant|--class|--timeout-seconds|--quantity)
            [ "$#" -ge 2 ] && [[ "$2" != --* && "$2" != -h ]] ||
                fail 'missing command option value'
            value="$2"; shift 2 ;;
        --event-id=*|--tenant=*|--class=*|--timeout-seconds=*|--quantity=*)
            value="${option#*=}"; option="${option%%=*}"; shift ;;
        *) fail 'invalid command option; use --help' ;;
    esac
    [ -n "$value" ] || fail 'command option values must be nonempty'
    case "$option" in
        --event-id)
            [ -z "$event_id" ] || fail 'duplicate event ID'
            [[ "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
                fail 'event ID must be a canonical UUID'
            event_id="$value" ;;
        --tenant)
            if [ "$command_name" = check_seats ]; then continue; fi
            [ "$command_name" = read ] && [ -z "$tenant" ] ||
                fail '--tenant is accepted once for read only; create and reserve_seat use PASETO_TOKEN'
            tenant="$value"
            printf '%s' "$tenant" | jq -Rse 'utf8bytelength >= 1 and utf8bytelength <= 64' \
                >/dev/null || fail 'tenant must contain 1-64 UTF-8 bytes' ;;
        --timeout-seconds)
            [ "$command_name" = create ] || fail '--timeout-seconds requires create'
            timeout_seconds="$value" ;;
        --quantity)
            [ "$command_name" = reserve_seat ] && [ -z "$quantity" ] ||
                fail '--quantity is accepted once for reserve_seat only'
            [[ "$value" =~ ^[0-9]+$ ]] &&
                jq -en --arg n "$value" '$n|tonumber|. >= 1 and . <= 4294967295' \
                    >/dev/null 2>&1 || fail 'quantity must be a positive u32 integer'
            quantity="$value" ;;
        --class)
            if [ "$command_name" = reserve_seat ]; then
                [ -z "$seat_class" ] || fail 'reserve_seat accepts exactly one --class tag'
                seat_class="$(jq -ern --arg tag "$value" '
                    $tag | select(utf8bytelength >= 1 and utf8bytelength <= 54 and
                        (explode|all(. > 31 and (. < 127 or . > 159))) and
                        . != "capacity" and . != "allocation")
                ' 2>/dev/null)" || fail 'invalid seat class tag'
                # Reject invalid UTF-8 rather than accepting jq replacement characters.
                [ "$seat_class" = "$value" ] || fail 'invalid seat class tag'
                continue
            fi
            [ "$command_name" = create ] || fail '--class requires create or reserve_seat'
            [[ "$value" == *=* ]] || fail 'class must be TAG=COUNT'
            tag="${value%=*}" count="${value##*=}"
            [[ "$count" =~ ^[0-9]+$ ]] || fail 'seat counts must be positive u32 integers'
            class_count=$((class_count + 1))
            [ "$class_count" -le 31 ] || fail 'create accepts at most 31 classes'
            classes="$(printf '%s' "$classes" | jq -ce --arg tag "$tag" --arg n "$count" '
                ($n|tonumber) as $count
                | if ($tag|utf8bytelength) >= 1 and ($tag|utf8bytelength) <= 54 and
                    ($tag|explode|all(. > 31 and (. < 127 or . > 159))) and
                    $tag != "capacity" and $tag != "allocation" and (has($tag)|not) and
                    $count >= 1 and $count <= 4294967295
                  then . + {($tag):$count} else error("invalid class") end
            ' 2>/dev/null)" || fail 'invalid or duplicate class; use a valid tag and positive u32 count' ;;
    esac
done

owner_token="${PASETO_TOKEN:-}"
unset PASETO_TOKEN PASETO_FOREIGN_TOKEN PASETO_PRIVATE_KEY
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$command_name" = create ]; then
    [ "$class_count" -gt 0 ] || fail 'create requires at least one --class TAG=COUNT'
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] &&
        jq -en --arg n "$timeout_seconds" '$n|tonumber|. >= 1 and . <= 4294967295' \
            >/dev/null 2>&1 || fail 'timeout must be a positive u32 integer'
    if [ -z "$event_id" ]; then
        event_id="$(new_uuid)"
    fi
    operation_id="$event_id"
    request="$(jq -cn --arg id "$event_id" --argjson classes "$classes" \
        --arg timeout "$timeout_seconds" '{id:$id,name:"SeatReservation",body:{
            command:"create_event",classes:$classes,timeout_seconds:($timeout|tonumber)}}')"
else
    if [ "$command_name" = read ]; then
        [ -n "$tenant" ] && [ -n "$event_id" ] || fail 'read requires --tenant and --event-id'
        [ -x "$root/zig-out/bin/events" ] || fail 'missing executable: run zig build build-events first'
    else
        [ -n "$event_id" ] || fail "$command_name requires --event-id"
        if [ "$command_name" = reserve_seat ]; then
            [ -n "$seat_class" ] && [ -n "$quantity" ] ||
                fail 'reserve_seat requires --class and --quantity'
        fi
        operation_id="$(new_uuid)"
        if [ "$command_name" = reserve_seat ]; then
            request="$(jq -cn --arg id "$operation_id" --arg event "$event_id" \
                --arg class "$seat_class" --arg n "$quantity" \
                '{id:$id,name:"SeatReservation",body:{command:"reserve_seats",event_id:$event,
                    class:$class,quantity:($n|tonumber)}}')"
        else
            request="$(jq -cn --arg id "$operation_id" --arg event "$event_id" \
                '{id:$id,name:"SeatReservation",body:{command:"check_seats",event_id:$event}}')"
        fi
    fi
fi
if [ "$command_name" != read ]; then
    [[ "$owner_token" =~ ^v4\.public\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?$ &&
        "${#owner_token}" -le 16384 ]] || fail 'PASETO_TOKEN must be a v4.public token'
    command -v curl >/dev/null 2>&1 || fail 'missing required command: curl'
fi
command -v aws >/dev/null 2>&1 || fail 'missing required command: aws'
aws_run() {
    if [ "$explicit_profile" = true ]; then
        aws "$@" --profile "$profile" --no-cli-pager --cli-connect-timeout 5 --cli-read-timeout 10
    else
        aws "$@" --no-cli-pager --cli-connect-timeout 5 --cli-read-timeout 10
    fi
}

# Let AWS resolve inherited credentials before exporting them for the host SDK.
[ -z "$profile" ] || export AWS_PROFILE="$profile"
unset AWS_DEFAULT_PROFILE
export AWS_REGION="$region" AWS_DEFAULT_REGION="$region" AWS_EC2_METADATA_DISABLED=true
if ! credentials="$(aws_run configure export-credentials --format process 2>/dev/null)"; then
    sso_configuration="$(aws_run configure get sso_session 2>/dev/null || true)"
    if [ -z "$sso_configuration" ]; then
        sso_configuration="$(aws_run configure get sso_start_url 2>/dev/null || true)"
    fi
    [ -n "$sso_configuration" ] ||
        fail 'AWS credential export failed; authenticate the selected identity'
    printf 'events: AWS credentials unavailable; signing in with AWS SSO\n' >&2
    aws_run sso login >&2 || fail 'AWS SSO login failed; authenticate the selected identity'
    credentials="$(aws_run configure export-credentials --format process 2>/dev/null)" ||
        fail 'AWS credential export failed after SSO login; authenticate the selected identity'
    unset sso_configuration
fi
printf '%s' "$credentials" | jq -e 'type == "object" and
    all(.AccessKeyId,.SecretAccessKey; type == "string" and length > 0) and
    (.SessionToken == null or (.SessionToken|type == "string"))' >/dev/null 2>&1 ||
    fail 'AWS credential export omitted credentials'
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
export AWS_ACCESS_KEY_ID="$(printf '%s' "$credentials" | jq -r .AccessKeyId)"
export AWS_SECRET_ACCESS_KEY="$(printf '%s' "$credentials" | jq -r .SecretAccessKey)"
session_token="$(printf '%s' "$credentials" | jq -r '.SessionToken // empty')"
[ -z "$session_token" ] || export AWS_SESSION_TOKEN="$session_token"
unset credentials session_token

if [ "$command_name" = read ]; then
    events_table="$(aws_run cloudformation describe-stack-resource \
        --stack-name "$stack_name" --logical-resource-id SeatEventsTable \
        --query StackResourceDetail.PhysicalResourceId --output text --region "$region" 2>/dev/null)" ||
        fail 'failed to resolve SeatEventsTable from the selected stack'
    [ -n "$events_table" ] && [ "$events_table" != None ] ||
        fail 'selected stack has no SeatEventsTable resource'
    export EVENTS_TABLE_NAME="$events_table"
    exec "$root/zig-out/bin/events" read --tenant "$tenant" --event-id "$event_id"
fi

stack_url() {
    local key="$1" url
    url="$(aws_run cloudformation describe-stacks --stack-name "$stack_name" \
        --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue | [0]" \
        --output text --region "$region" 2>/dev/null)" ||
        fail "failed to resolve $key from the selected stack"
    printf '%s' "$url" | jq -Rse \
        'test("^https://(\\[[0-9a-fA-F:.]+\\]|[^/?#@:[:space:]]+)(:[0-9]+)?/?$")' \
        >/dev/null || fail "selected stack has no valid $key output"
    printf '%s\n' "$url"
}

expected_tenant=null
http_operation() {
    local method="$1" url="$2" body="${3:-}" response status
    # Keep the bearer token out of process arguments and temporary files.
    response="$(
        {
            printf 'url = %s\n' "$(printf '%s' "$url" | jq -Rs .)"
            printf 'request = "%s"\nsilent\nshow-error\nconnect-timeout = 5\nmax-time = 30\n' "$method"
            printf 'max-filesize = 65536\nproto = "=https"\nwrite-out = "\\n%%{http_code}"\n'
            printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "$owner_token" | jq -Rs .)"
            if [ -n "$body" ]; then
                printf 'header = "Content-Type: application/json"\ndata = %s\n' \
                    "$(printf '%s' "$body" | jq -Rs .)"
            fi
        } | curl --disable --config - 2>/dev/null
    )" || {
        if [ "$command_name" = create ]; then
            fail "creation request failed; retry with --event-id $event_id and the same classes and timeout"
        fi
        fail "$method request failed for Operation $operation_id"
    }
    [[ "$response" == *$'\n'* ]] || fail "invalid $method response for Operation $operation_id"
    status="${response##*$'\n'}"
    [[ "$status" =~ ^[0-9]{3}$ ]] || fail "invalid $method HTTP status for Operation $operation_id"
    if [ "$status" != 200 ]; then
        if [ "$command_name" = create ]; then
            fail "intake returned HTTP $status for Operation $operation_id; retry with the same ID and configuration"
        fi
        fail "$method returned HTTP $status for Operation $operation_id"
    fi
    printf '%s' "${response%$'\n'*}" | jq -cse --arg id "$operation_id" \
        --argjson tenant "$expected_tenant" --arg command "$command_name" '
        (if length == 1 then .[0] else error("expected one Operation") end) |
        if type == "object" and .id == $id and .name == "SeatReservation" and
            (.state == "SUBMITTED" or .state == "COMPLETED") and
            (.tenant|type == "string" and utf8bytelength >= 1 and utf8bytelength <= 64) and
            ($tenant == null or .tenant == $tenant) and
            ($command == "create" or
                (if .state == "COMPLETED" then
                    (.result|type == "object" and
                        (.type == "SUCCESS" or .type == "FAILURE") and .payload != null)
                 else true end))
        then . else error("invalid Operation") end
    ' 2>/dev/null || fail "invalid $method Operation response for $operation_id"
}

intake_url="$(stack_url IntakeFunctionUrl)"
if [ "$command_name" = create ]; then
    http_operation POST "$intake_url" "$request"
    exit 0
fi

# Resolve both endpoints before submitting work, so discovery failures create no Operation.
query_url="$(stack_url QueryFunctionUrl)"
operation="$(http_operation POST "$intake_url" "$request")"
# The authenticated handler supplies the tenant; preserve its exact JSON string.
expected_tenant="$(printf '%s' "$operation" | jq -c .tenant)"
while :; do
    operation="$(http_operation GET "${query_url%/}/$operation_id")"
    printf '%s\n' "$operation"
    if [ "$(printf '%s' "$operation" | jq -r .state)" = COMPLETED ]; then
        exit 0
    fi
    sleep 1
done
