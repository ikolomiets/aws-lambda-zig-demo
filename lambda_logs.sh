#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
readonly AWS_PROFILE AWS_REGION
export AWS_PROFILE AWS_REGION

readonly stack_name="aws-lambda-zig-demo"

usage() {
    cat <<'EOF'
Usage: ./lambda_logs.sh

Download the aws-lambda-zig-demo Lambda logs and append new CloudWatch events
to <function-name>.log in this repository.

Environment overrides:
  AWS_PROFILE    AWS CLI profile. Defaults to dev.
  AWS_REGION     AWS region. Defaults to ca-central-1.
EOF
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

case "$#" in
    0) ;;
    1)
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            *) fail "unknown option: $1" ;;
        esac
        ;;
    *) fail "this command accepts no arguments" ;;
esac

need_command aws
need_command jq

cd "$(dirname "$0")"

function_name="$(
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue | [0]" \
        --output text \
        --no-cli-pager
)" || fail "failed to resolve FunctionName from stack $stack_name; run: aws sso login --profile $AWS_PROFILE"

case "$function_name" in
    "" | None)
        fail "stack $stack_name has no FunctionName output"
        ;;
    *[!A-Za-z0-9_-]*)
        fail "stack $stack_name returned an invalid FunctionName"
        ;;
esac
[ "${#function_name}" -le 64 ] || fail "stack $stack_name returned an invalid FunctionName"

readonly function_name
readonly log_group_name="/aws/lambda/$function_name"
readonly log_file="$function_name.log"

[ ! -L "$log_file" ] || fail "refusing to write through symbolic link: $log_file"
if [ -e "$log_file" ] && [ ! -f "$log_file" ]; then
    fail "log path is not a regular file: $log_file"
fi

temporary_dir="$(mktemp -d)" || fail "failed to create temporary directory"
readonly temporary_dir
cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT

readonly response_file="$temporary_dir/response.json"
readonly selected_events_file="$temporary_dir/selected-events.json"
readonly rendered_events_file="$temporary_dir/rendered-events.log"
readonly cursor_ids_file="$temporary_dir/cursor-event-ids.txt"

cursor_epoch_ms=-1
start_time=0
: >"$cursor_ids_file"

if [ -s "$log_file" ]; then
    cursor_timestamp="$(
        awk '
            /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9] \[event-id=[^]]+\] / {
                timestamp = substr($0, 1, 23)
            }
            END {
                if (timestamp != "") print timestamp
            }
        ' "$log_file"
    )"
    [ -n "$cursor_timestamp" ] ||
        fail "non-empty log has no recognizable event header: $log_file"

    cursor_epoch_ms="$(
        jq -nr \
            --arg timestamp "${cursor_timestamp%.*}Z" \
            --arg milliseconds "${cursor_timestamp##*.}" \
            '(($timestamp | fromdateiso8601) * 1000) + ($milliseconds | tonumber)'
    )" || fail "invalid final event timestamp in $log_file"
    case "$cursor_epoch_ms" in
        "" | *[!0-9]*) fail "invalid final event timestamp in $log_file" ;;
    esac
    start_time="$cursor_epoch_ms"

    awk -v timestamp="$cursor_timestamp" '
        index($0, timestamp " [event-id=") == 1 {
            event_id = substr($0, length(timestamp " [event-id=") + 1)
            marker = index(event_id, "] ")
            if (marker > 1) print substr(event_id, 1, marker - 1)
        }
    ' "$log_file" >"$cursor_ids_file"
fi

printf '==> Downloading %s logs from %s\n' "$function_name" "$AWS_REGION"
aws logs filter-log-events \
    --log-group-name "$log_group_name" \
    --start-time "$start_time" \
    --start-from-head \
    --query events \
    --output json \
    --no-cli-pager \
    >"$response_file" ||
    fail "failed to download $log_group_name; run: aws sso login --profile $AWS_PROFILE"

jq \
    --argjson cursor_epoch_ms "$cursor_epoch_ms" \
    --rawfile cursor_ids "$cursor_ids_file" \
    '
        def valid_event:
            (.timestamp | type) == "number" and
            .timestamp >= 0 and
            (.timestamp | floor) == .timestamp and
            (.eventId | type) == "string" and
            (.eventId | length) > 0 and
            (.message | type) == "string";

        if type != "array" then
            error("CloudWatch response events must be an array")
        elif any(.[]; valid_event | not) then
            error("CloudWatch response contains an invalid event")
        else
            .
        end
        | ($cursor_ids
            | split("\n")
            | map(select(length > 0))
            | reduce .[] as $event_id ({}; .[$event_id] = true)
          ) as $initial_seen
        | reduce .[] as $event (
            { events: [], last_timestamp: -1, seen: $initial_seen };
            if $event.timestamp < .last_timestamp then
                error("CloudWatch events are not ordered by timestamp")
            else
                .last_timestamp = $event.timestamp
                | ($event.eventId | @uri) as $event_id
                | if $event.timestamp < $cursor_epoch_ms or .seen[$event_id] then
                    .
                  else
                    .seen[$event_id] = true
                    | .events += [$event]
                  end
            end
          )
        | .events
    ' "$response_file" >"$selected_events_file" ||
    fail "invalid CloudWatch response; $log_file was not changed"

jq -jr '
    def render_timestamp:
        . as $milliseconds
        | (($milliseconds / 1000 | floor) | strftime("%Y-%m-%dT%H:%M:%S"))
          + "."
          + (((($milliseconds % 1000) + 1000) | tostring)[1:4]);

    .[]
    | (.eventId | @uri) as $event_id
    | ((.timestamp | render_timestamp)
        + " [event-id=" + $event_id + "] "
        + .message)
    | if endswith("\n") then . else . + "\n" end
' "$selected_events_file" >"$rendered_events_file" ||
    fail "failed to render CloudWatch events; $log_file was not changed"

event_count="$(jq -r 'length' "$selected_events_file")" ||
    fail "failed to count CloudWatch events; $log_file was not changed"

if [ "$event_count" -gt 0 ]; then
    command cat "$rendered_events_file" >>"$log_file" ||
        fail "failed to append CloudWatch events to $log_file"
    printf 'Appended %s event(s) to %s.\n' "$event_count" "$log_file"
else
    [ -e "$log_file" ] || : >"$log_file"
    printf 'No new events for %s.\n' "$function_name"
fi
