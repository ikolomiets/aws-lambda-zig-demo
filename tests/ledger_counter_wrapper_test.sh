#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ledger-counter-wrapper-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/work/zig-out/bin"
cp "$REPOSITORY_ROOT/ledger-counter.sh" "$TEST_DIR/work/ledger-counter.sh"
export AWS_CALLS="$TEST_DIR/aws-calls" COUNTER_ARGUMENTS="$TEST_DIR/arguments"
: >"$AWS_CALLS"
cat >"$TEST_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AWS_CALLS"
if [ "${FAIL_AWS:-0}" = 1 ]; then
    printf 'sensitive upstream diagnostic\n' >&2
    exit 7
fi
case "$1 $2" in
    'configure export-credentials')
        printf '%s\n' 'export AWS_ACCESS_KEY_ID=test-access' 'export AWS_SECRET_ACCESS_KEY=test-secret' 'export AWS_SESSION_TOKEN=test-session'
        ;;
    'cloudformation describe-stacks')
        if [ "${FAIL_DISCOVERY:-0}" = 1 ]; then
            printf 'sensitive upstream output\n'
            printf 'sensitive upstream diagnostic\n' >&2
            exit 7
        fi
        case "$*" in
            *LedgerCounterTableName*) printf '%s\n' "${RESOLVED_TABLE-shared-ledgers}" ;;
            *) exit 99 ;;
        esac
        ;;
    *) exit 99 ;;
esac
MOCK
cat >"$TEST_DIR/work/zig-out/bin/ledger-counter" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$LEDGER_COUNTER_TABLE_NAME|$AWS_REGION|$AWS_PROFILE|$AWS_EC2_METADATA_DISABLED"
printf '%s\0' "$@" >"$COUNTER_ARGUMENTS"
[ "$AWS_ACCESS_KEY_ID" = test-access ] && [ "$AWS_SECRET_ACCESS_KEY" = test-secret ] &&
    [ "$AWS_SESSION_TOKEN" = test-session ] || exit 98
exit "${COUNTER_EXIT:-0}"
MOCK
chmod +x "$TEST_DIR/bin/aws" "$TEST_DIR/work/zig-out/bin/ledger-counter"
export PATH="$TEST_DIR/bin:$PATH"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail_test "missing expected text: $2" ;; esac; }

# Help works before a binary is built and does not discover table or native configuration.
mv "$TEST_DIR/work/zig-out/bin/ledger-counter" "$TEST_DIR/counter-binary"
for args in '--help' 'init --help' 'read -h' 'allocate help'; do
    output="$(FAIL_AWS=1 bash "$TEST_DIR/work/ledger-counter.sh" $args)"
    contains "$output" 'ledger-counter allocate'
done
[ ! -s "$AWS_CALLS" ] || fail_test 'help contacted AWS'
mv "$TEST_DIR/counter-binary" "$TEST_DIR/work/zig-out/bin/ledger-counter"

# Different stacks reference the same table; stale environment and cluster selections cannot rebind it.
for stack in owner-stack reference-stack; do
    output="$(PROFILE=chosen-profile REGION=chosen-region STACK_NAME="$stack" \
        LEDGER_COUNTER_TABLE_NAME=stale-table TIGERBEETLE_CLUSTER_ID=123 \
        bash "$TEST_DIR/work/ledger-counter.sh" allocate)"
    contains "$output" 'shared-ledgers|chosen-region|chosen-profile|true'
    contains "$(cat "$AWS_CALLS")" "--stack-name $stack"
done
contains "$(cat "$AWS_CALLS")" '--region chosen-region'
contains "$(cat "$AWS_CALLS")" '--profile chosen-profile'
python3 - "$COUNTER_ARGUMENTS" "$AWS_CALLS" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes().split(b'\0') == [b'allocate', b'']
calls = Path(sys.argv[2]).read_text()
assert 'describe-stack-resource' not in calls
assert 'TigerBeetle' not in calls and 'cluster' not in calls
PY
output="$(RESOLVED_TABLE=externally-owned-ledgers bash "$TEST_DIR/work/ledger-counter.sh" \
    --profile override --region=override-region --stack-name override-stack read)"
contains "$output" 'externally-owned-ledgers|override-region|override|true'

long_table="$(printf '%0256d' 0)"
for table in '' None 'table with spaces' 'a' 'x/y' "$long_table" 'sensitive/table'; do
    : >"$COUNTER_ARGUMENTS"
    status=0
    if output="$(RESOLVED_TABLE="$table" bash "$TEST_DIR/work/ledger-counter.sh" init 2>&1)"; then
        fail_test 'invalid allocator binding accepted'
    else
        status=$?
    fi
    [ "$status" -eq 2 ] || fail_test 'invalid allocator binding exit code changed'
    contains "$output" 'LedgerCounterTableName'
    case "$output" in *sensitive*) fail_test 'invalid binding data leaked' ;; esac
    [ ! -s "$COUNTER_ARGUMENTS" ] || fail_test 'invalid binding invoked the binary'
done
: >"$COUNTER_ARGUMENTS"
status=0
if output="$(FAIL_DISCOVERY=1 bash "$TEST_DIR/work/ledger-counter.sh" read 2>&1)"; then
    fail_test 'discovery error accepted'
else
    status=$?
fi
[ "$status" -eq 2 ] || fail_test 'discovery error exit code changed'
contains "$output" 'LedgerCounterTableName'
case "$output" in *sensitive*) fail_test 'upstream discovery data leaked' ;; esac
[ ! -s "$COUNTER_ARGUMENTS" ] || fail_test 'failed discovery invoked the binary'
if output="$(FAIL_AWS=1 bash "$TEST_DIR/work/ledger-counter.sh" read 2>&1)"; then
    fail_test 'AWS error accepted'
fi
case "$output" in *sensitive*) fail_test 'upstream diagnostic leaked' ;; esac
for code in 1 2; do
    status=0
    COUNTER_EXIT="$code" bash "$TEST_DIR/work/ledger-counter.sh" allocate >/dev/null || status=$?
    [ "$status" -eq "$code" ] || fail_test 'binary exit code changed'
done
: >"$AWS_CALLS"
for command in reset decrement delete-all; do
    if bash "$TEST_DIR/work/ledger-counter.sh" "$command" >/dev/null 2>&1; then
        fail_test 'forbidden command accepted'
    fi
done
[ ! -s "$AWS_CALLS" ] || fail_test 'forbidden command contacted AWS'
printf 'PASS: Ledger counter wrapper regression tests\n'
