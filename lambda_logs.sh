#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dev}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
readonly AWS_PROFILE AWS_REGION
export AWS_PROFILE AWS_REGION

readonly stack_name="aws-lambda-zig-demo"

usage() {
    cat <<'EOF'
Usage: ./lambda_logs.sh intake|query|execution

Download one Lambda's logs and append new CloudWatch events to
<function-name>.log in this repository.

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
    1) ;;
    *) fail "specify exactly one Lambda: intake, query, or execution" ;;
esac
case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    intake)
        readonly function_output_key="IntakeFunctionName"
        ;;
    query)
        readonly function_output_key="QueryFunctionName"
        ;;
    execution)
        readonly function_output_key="ExecutionFunctionName"
        ;;
    *) fail "unknown Lambda: $1; expected intake, query, or execution" ;;
esac

need_command aws
need_command jq

cd "$(dirname "$0")"

function_name="$(
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query "Stacks[0].Outputs[?OutputKey=='$function_output_key'].OutputValue | [0]" \
        --output text \
        --no-cli-pager
)" || fail "failed to resolve $function_output_key from stack $stack_name; run: aws sso login --profile $AWS_PROFILE"

case "$function_name" in
    "" | None)
        fail "stack $stack_name has no $function_output_key output"
        ;;
    *[!A-Za-z0-9_-]*)
        fail "stack $stack_name returned an invalid $function_output_key"
        ;;
esac
[ "${#function_name}" -le 64 ] ||
    fail "stack $stack_name returned an invalid $function_output_key"

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

cursor_epoch_ms=-1
start_time=0

if [ -s "$log_file" ]; then
    if awk '
        /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9] \[event-id=[^]]+\] / {
            found = 1
            exit
        }
        END {
            exit found ? 0 : 1
        }
    ' "$log_file"; then
        fail "legacy event-id headers are unsupported; remove or rename $log_file"
    fi

    cursor_timestamp="$(
        awk '
            /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9] / {
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
    start_time=$((cursor_epoch_ms + 1))
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
        | reduce .[] as $event (
            { events: [], last_timestamp: -1, seen: {} };
            if $event.timestamp < .last_timestamp then
                error("CloudWatch events are not ordered by timestamp")
            else
                .last_timestamp = $event.timestamp
                | ($event.eventId | @uri) as $event_id
                | if $event.timestamp <= $cursor_epoch_ms or .seen[$event_id] then
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
    | ((.timestamp | render_timestamp)
        + " "
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
