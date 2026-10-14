#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-dev}"
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"
explicit_id=false
selected_id=''

fail() { printf 'ledger-counter: %s\n' "$1" >&2; exit 2; }
usage() {
    cat <<'USAGE'
Usage:
  ledger-counter.sh [--profile <profile>] [--region <region>] [--stack-name <stack>] [--counter-id <id>] <command>
  ledger-counter init
  ledger-counter read
  ledger-counter allocate

Defaults: PROFILE=dev, REGION=ca-central-1, STACK_NAME=aws-lambda-zig-demo.
Init is explicit first-time absent-only setup at 1000. Existing state is preserved.
ID precedence: --counter-id, LEDGER_COUNTER_ID, optional LedgerCounterId output, global.
IDs are 1-128 ASCII bytes: letter/digit first, then letters, digits, dot, underscore or hyphen.
Participants share a sequence only with the same table and ID; independent IDs may overlap.
Execution resolves the stack's LedgerCounterTableName output, including referenced tables.
Deployment wiring is added separately. No reset, decrement, recycle, or delete command exists.
USAGE
}
validate_id() {
    local LC_ALL=C
    [ "${#1}" -ge 1 ] && [ "${#1}" -le 128 ] &&
        [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || fail 'invalid counter ID'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h|help) usage; exit 0 ;;
        --counter-id)
            [ "$explicit_id" = false ] || fail 'duplicate counter ID option'
            [ "$#" -ge 2 ] || fail 'missing counter ID option value'
            validate_id "$2"
            selected_id="$2"
            explicit_id=true
            shift 2
            ;;
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
supplied_id="$explicit_id"
if [ "$explicit_id" = false ] && [ "${LEDGER_COUNTER_ID+x}" = x ]; then
    validate_id "$LEDGER_COUNTER_ID"
    selected_id="$LEDGER_COUNTER_ID"
    supplied_id=true
fi
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
if [ "$supplied_id" = false ]; then
    # Separate presence from value and append a suffix to preserve invalid trailing newlines.
    id_output="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query 'join(`":"`, [to_string(length(Stacks[0].Outputs[?OutputKey==`LedgerCounterId`])), to_string(Stacks[0].Outputs[?OutputKey==`LedgerCounterId`].OutputValue | [0]), `""`])' \
        --output text --profile "$PROFILE" --region "$REGION" 2>/dev/null)" ||
        fail 'failed to resolve optional LedgerCounterId from the selected stack'
    case "$id_output" in
        0:null:) selected_id=global ;;
        1:*:) selected_id="${id_output#1:}"; selected_id="${selected_id%:}" ;;
        *) fail 'invalid counter ID output from the selected stack' ;;
    esac
    validate_id "$selected_id"
    unset id_output
fi
export LEDGER_COUNTER_ID="$selected_id"
if [ "$explicit_id" = true ]; then
    exec ./zig-out/bin/ledger-counter --counter-id "$selected_id" "$@"
fi
exec ./zig-out/bin/ledger-counter "$@"
