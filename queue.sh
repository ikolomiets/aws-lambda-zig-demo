#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-dev}"
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

command -v aws >/dev/null 2>&1 || fail "missing required command: aws"

cd "$(dirname "$0")"
[ -x zig-out/bin/sqs ] || fail "missing executable: run zig build first"

credential_exports="$(
    aws configure export-credentials \
        --profile "$PROFILE" \
        --format env
)" || fail "AWS credential export failed; run: aws sso login --profile $PROFILE"
[ -n "$credential_exports" ] || fail "AWS credential export returned no credentials"
eval "$credential_exports"
unset credential_exports

[ -n "${AWS_ACCESS_KEY_ID:-}" ] || fail "AWS credential export omitted the access key"
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || fail "AWS credential export omitted the secret key"
[ -n "${AWS_SESSION_TOKEN:-}" ] || fail "AWS credential export omitted the session token"

export AWS_PROFILE="$PROFILE"
export AWS_REGION="$REGION"
export AWS_EC2_METADATA_DISABLED=true

tigerbeetle_queue_url="$(
    aws cloudformation describe-stack-resource \
        --stack-name "$STACK_NAME" \
        --logical-resource-id TigerBeetleQueue \
        --query StackResourceDetail.PhysicalResourceId \
        --output text \
        --region "$REGION"
)" || fail "failed to resolve TigerBeetleQueue from stack $STACK_NAME"
[ -n "$tigerbeetle_queue_url" ] || fail "stack $STACK_NAME has no TigerBeetleQueue resource"
[ "$tigerbeetle_queue_url" != "None" ] || fail "stack $STACK_NAME has no TigerBeetleQueue resource"
export TigerBeetleQueue="$tigerbeetle_queue_url"
unset tigerbeetle_queue_url

exec ./zig-out/bin/sqs "$@"
