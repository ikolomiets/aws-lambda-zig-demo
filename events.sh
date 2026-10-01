#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-dev}"
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"

fail() { printf 'events: %s\n' "$1" >&2; exit 2; }
usage() {
    cat <<'USAGE'
Usage:
  events.sh [--profile <profile>] [--region <region>] [--stack-name <stack>] <command>
  events create --tenant <tenant> --event-id <uuid> < event.json
  events read --tenant <tenant> --event-id <uuid>

Defaults: PROFILE=dev, REGION=ca-central-1, STACK_NAME=aws-lambda-zig-demo.
Creation inserts validated creating metadata only; it does not provision native resources.
Execution requires the selected stack's SeatEventsTable. Deployment wiring is added separately.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h|help) usage; exit 0 ;;
        --profile|--region|--stack-name)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail 'missing wrapper option value'
            case "$1" in
                --profile) PROFILE="$2" ;;
                --region) REGION="$2" ;;
                --stack-name) STACK_NAME="$2" ;;
            esac
            shift 2
            ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        --region=*) REGION="${1#*=}"; shift ;;
        --stack-name=*) STACK_NAME="${1#*=}"; shift ;;
        create|read) break ;;
        *) fail 'invalid invocation; use --help' ;;
    esac
done
[ "$#" -gt 0 ] || fail 'missing command; use --help'
if [ "$#" -eq 2 ]; then
    case "$2" in --help|-h|help) usage; exit 0 ;; esac
fi
[ -n "$PROFILE" ] && [ -n "$REGION" ] && [ -n "$STACK_NAME" ] || fail 'invalid wrapper configuration'
cd "$(dirname "$0")"
[ -x zig-out/bin/events ] || fail 'missing executable: run zig build build-events first'
command -v aws >/dev/null 2>&1 || fail 'missing required command: aws'

credential_exports="$(aws configure export-credentials --profile "$PROFILE" --format env 2>/dev/null)" ||
    fail 'AWS credential export failed; authenticate the selected profile'
[ -n "$credential_exports" ] || fail 'AWS credential export returned no credentials'
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
# AWS CLI supplies shell-formatted environment exports, as in the existing wrappers.
eval "$credential_exports"
unset credential_exports
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] &&
    [ -n "${AWS_SESSION_TOKEN:-}" ] || fail 'AWS credential export omitted credentials'
export AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
export AWS_EC2_METADATA_DISABLED=true

events_table="$(aws cloudformation describe-stack-resource \
    --stack-name "$STACK_NAME" --logical-resource-id SeatEventsTable \
    --query StackResourceDetail.PhysicalResourceId --output text \
    --profile "$PROFILE" --region "$REGION" 2>/dev/null)" ||
    fail 'failed to resolve SeatEventsTable from the selected stack'
[ -n "$events_table" ] && [ "$events_table" != None ] || fail 'selected stack has no SeatEventsTable resource'
export EVENTS_TABLE_NAME="$events_table"
unset events_table
exec ./zig-out/bin/events "$@"
