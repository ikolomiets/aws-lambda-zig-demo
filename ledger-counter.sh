#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-dev}"
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"

fail() { printf 'ledger-counter: %s\n' "$1" >&2; exit 2; }
usage() {
    cat <<'USAGE'
Usage:
  ledger-counter.sh [--profile <profile>] [--region <region>] [--stack-name <stack>] <command>
  ledger-counter init
  ledger-counter read
  ledger-counter allocate

Defaults: PROFILE=dev, REGION=ca-central-1, STACK_NAME=aws-lambda-zig-demo.
Init is explicit first-time absent-only setup at 1000. Existing state is preserved.
All participants share the selected global allocator table; native cluster identity is irrelevant.
Execution resolves the stack's LedgerCounterTableName output, including referenced tables.
Deployment wiring is added separately. No reset, decrement, recycle, or delete command exists.
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
        init|read|allocate) break ;;
        *) fail 'invalid invocation; use --help' ;;
    esac
done
[ "$#" -gt 0 ] || fail 'missing command; use --help'
if [ "$#" -eq 2 ]; then
    case "$2" in --help|-h|help) usage; exit 0 ;; esac
fi
[ "$#" -eq 1 ] || fail 'invalid invocation; use --help'
[ -n "$PROFILE" ] && [ -n "$REGION" ] && [ -n "$STACK_NAME" ] || fail 'invalid wrapper configuration'
cd "$(dirname "$0")"
[ -x zig-out/bin/ledger-counter ] || fail 'missing executable: run zig build build-ledger-counter first'
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

# The output is the actual binding for either an owned or a referenced table.
# Never fall back to an owned logical resource or a native cluster parameter.
counter_table="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[?OutputKey==`LedgerCounterTableName`].OutputValue | [0]' \
    --output text --profile "$PROFILE" --region "$REGION" 2>/dev/null)" ||
    fail 'failed to resolve LedgerCounterTableName from the selected stack; verify AWS access and the required global allocator output'
[ "$counter_table" != None ] && [ "${#counter_table}" -ge 3 ] &&
    [ "${#counter_table}" -le 255 ] || fail 'selected stack requires a valid LedgerCounterTableName output for the global allocator'
case "$counter_table" in
    *[!a-zA-Z0-9_.-]*) fail 'selected stack requires a valid LedgerCounterTableName output for the global allocator' ;;
esac
export LEDGER_COUNTER_TABLE_NAME="$counter_table"
unset counter_table
exec ./zig-out/bin/ledger-counter "$@"
