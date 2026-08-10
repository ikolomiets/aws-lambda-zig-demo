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

delete_all_command=0
if [ "${1:-}" = "delete-all" ]; then
    [ "$#" -eq 1 ] || fail "delete-all accepts no arguments"
    command -v jq >/dev/null 2>&1 || fail "missing required command: jq"
    delete_all_command=1
else
    [ -x zig-out/bin/dynamodb ] || fail "missing executable: run zig build first"
fi

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

operations_table_name="$(
    aws cloudformation describe-stack-resource \
        --stack-name "$STACK_NAME" \
        --logical-resource-id OperationsTable \
        --query StackResourceDetail.PhysicalResourceId \
        --output text \
        --region "$REGION"
)" || fail "failed to resolve OperationsTable from stack $STACK_NAME"
[ -n "$operations_table_name" ] || fail "stack $STACK_NAME has no OperationsTable resource"
[ "$operations_table_name" != "None" ] || fail "stack $STACK_NAME has no OperationsTable resource"
export OPERATIONS_TABLE_NAME="$operations_table_name"

if [ "$delete_all_command" -eq 1 ]; then
    scan_file="$(mktemp)" || fail "failed to create temporary file"
    trap 'rm -f "$scan_file"' EXIT

    aws dynamodb scan \
        --table-name "$OPERATIONS_TABLE_NAME" \
        --projection-expression id \
        --consistent-read \
        --region "$REGION" \
        --output json \
        --no-cli-pager \
        >"$scan_file" || fail "failed to scan Operations table"

    operation_count="$(jq -er '.Items | length' "$scan_file")" ||
        fail "invalid scan response"
    if [ "$operation_count" -eq 0 ]; then
        printf 'Operations table is already empty.\n'
        exit 0
    fi

    printf 'Found %s Operation(s) in stack %s (%s).\n' \
        "$operation_count" \
        "$STACK_NAME" \
        "$REGION"
    printf 'Type delete to permanently delete every Operation: '
    IFS= read -r confirmation || fail "confirmation input closed"
    [ "$confirmation" = "delete" ] || fail "deletion cancelled"

    jq -c '.Items[] | {id: .id}' "$scan_file" |
        while IFS= read -r key; do
            aws dynamodb delete-item \
                --table-name "$OPERATIONS_TABLE_NAME" \
                --key "$key" \
                --region "$REGION" \
                --no-cli-pager \
                >/dev/null
        done

    remaining_count="$(
        aws dynamodb scan \
            --table-name "$OPERATIONS_TABLE_NAME" \
            --projection-expression id \
            --consistent-read \
            --region "$REGION" \
            --output json \
            --no-cli-pager |
            jq -er '.Items | length'
    )" || fail "failed to verify Operations table"
    [ "$remaining_count" -eq 0 ] ||
        fail "$remaining_count Operation(s) remain after deletion"

    printf 'Deleted %s Operation(s); the table is empty.\n' "$operation_count"
    exit 0
fi

unset operations_table_name

exec ./zig-out/bin/dynamodb "$@"
