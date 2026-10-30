#!/usr/bin/env bash
set -euo pipefail

profile="${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-${PROFILE:-}}}"
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-${REGION:-ca-central-1}}}"
stack_name="${STACK_NAME:-aws-lambda-zig-demo}"
explicit_profile=false

fail() { printf 'events: %s\n' "$1" >&2; exit 2; }
usage() {
    cat <<'USAGE'
Usage:
  events.sh [--profile PROFILE] [--region REGION] [--stack-name STACK] <command>
  events.sh create --class TAG=COUNT [--class TAG=COUNT ...]
                   [--timeout-seconds SECONDS] [--event-id UUID]
  events.sh read --tenant TENANT --event-id UUID

Create requires explicit seat classes and counts and PASETO_TOKEN; no stdin JSON.
It submits an authenticated SeatReservation create_event Operation to the stack's
IntakeFunctionUrl. The verified token supplies the tenant; processors allocate
the ledger and native IDs. Output is the submitted Operation, not readiness evidence.
Use --event-id to retry the same creation; otherwise a fresh UUID is generated.
Reservation timeout defaults to 300 seconds. Counts and timeout are positive u32.
Read returns persisted Event metadata using the prebuilt zig-out/bin/events utility.
Read requires explicit --tenant and --event-id; AWS credentials authorize metadata reads.

Options override the environment. Profile: AWS_PROFILE, AWS_DEFAULT_PROFILE,
PROFILE, or the AWS CLI default credential chain. Region: AWS_REGION,
AWS_DEFAULT_REGION, REGION, or ca-central-1. STACK_NAME defaults to aws-lambda-zig-demo.
An inherited profile preserves environment credentials; --profile explicitly selects it.
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
        create|read) break ;;
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

event_id= tenant= timeout_seconds=300 classes='{}' class_count=0
while [ "$#" -gt 0 ]; do
    option="$1"
    case "$option" in
        --event-id|--tenant|--class|--timeout-seconds)
            [ "$#" -ge 2 ] && [[ "$2" != --* && "$2" != -h ]] ||
                fail 'missing command option value'
            value="$2"; shift 2 ;;
        --event-id=*|--tenant=*|--class=*|--timeout-seconds=*)
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
            [ "$command_name" = read ] && [ -z "$tenant" ] ||
                fail '--tenant is accepted once for read only; create uses PASETO_TOKEN'
            tenant="$value"
            printf '%s' "$tenant" | jq -Rse 'utf8bytelength >= 1 and utf8bytelength <= 64' \
                >/dev/null || fail 'tenant must contain 1-64 UTF-8 bytes' ;;
        --timeout-seconds)
            [ "$command_name" = create ] || fail '--timeout-seconds requires create'
            timeout_seconds="$value" ;;
        --class)
            [ "$command_name" = create ] || fail '--class requires create'
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
    [[ "$owner_token" =~ ^v4\.public\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?$ &&
        "${#owner_token}" -le 16384 ]] || fail 'PASETO_TOKEN must be a v4.public token'
    command -v curl >/dev/null 2>&1 || fail 'missing required command: curl'
    if [ -z "$event_id" ]; then
        hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
        [ "${#hex}" -eq 32 ] || fail 'could not generate Operation UUID'
        variant="$(printf '%x' "$(( (16#${hex:16:1} & 3) | 8 ))")"
        event_id="${hex:0:8}-${hex:8:4}-4${hex:13:3}-$variant${hex:17:3}-${hex:20:12}"
    fi
    request="$(jq -cn --arg id "$event_id" --argjson classes "$classes" \
        --arg timeout "$timeout_seconds" '{id:$id,name:"SeatReservation",body:{
            command:"create_event",classes:$classes,timeout_seconds:($timeout|tonumber)}}')"
else
    [ -n "$tenant" ] && [ -n "$event_id" ] || fail 'read requires --tenant and --event-id'
    [ -x "$root/zig-out/bin/events" ] || fail 'missing executable: run zig build build-events first'
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
credentials="$(aws_run configure export-credentials --format process 2>/dev/null)" ||
    fail 'AWS credential export failed; authenticate the selected identity'
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

intake_url="$(aws_run cloudformation describe-stacks --stack-name "$stack_name" \
    --query "Stacks[0].Outputs[?OutputKey=='IntakeFunctionUrl'].OutputValue | [0]" \
    --output text --region "$region" 2>/dev/null)" ||
    fail 'failed to resolve IntakeFunctionUrl from the selected stack'
printf '%s' "$intake_url" | jq -Rse \
    'test("^https://(\\[[0-9a-fA-F:.]+\\]|[^/?#@:[:space:]]+)(:[0-9]+)?/?$")' \
    >/dev/null || fail 'selected stack has no valid IntakeFunctionUrl output'
# Keep the bearer token out of process arguments and temporary files.
response="$(
    {
        printf 'url = %s\n' "$(printf '%s' "$intake_url" | jq -Rs .)"
        printf 'request = "POST"\nsilent\nshow-error\nconnect-timeout = 5\nmax-time = 30\n'
        printf 'max-filesize = 65536\nproto = "=https"\nwrite-out = "\\n%%{http_code}"\n'
        printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "$owner_token" | jq -Rs .)"
        printf 'header = "Content-Type: application/json"\ndata = %s\n' \
            "$(printf '%s' "$request" | jq -Rs .)"
    } | curl --disable --config - 2>/dev/null
)" || fail "creation request failed; retry with --event-id $event_id and the same classes and timeout"
[[ "$response" == *$'\n'* ]] || fail "invalid intake response for Operation $event_id"
status="${response##*$'\n'}"
[[ "$status" =~ ^[0-9]{3}$ ]] || fail "invalid intake HTTP status for Operation $event_id"
[ "$status" = 200 ] || fail "intake returned HTTP $status for Operation $event_id; retry with the same ID and configuration"
printf '%s' "${response%$'\n'*}" | jq -ce --arg id "$event_id" '
    if type == "object" and .id == $id and .name == "SeatReservation" and
        (.state == "SUBMITTED" or .state == "COMPLETED") and
        (.tenant|type == "string" and utf8bytelength >= 1 and utf8bytelength <= 64)
    then . else error("invalid Operation") end
' 2>/dev/null || fail "invalid intake Operation response for $event_id"
