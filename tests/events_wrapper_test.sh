#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/events-wrapper-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/work/zig-out/bin"
cp "$REPOSITORY_ROOT/events.sh" "$TEST_DIR/work/events.sh"
export AWS_CALLS="$TEST_DIR/aws-calls" EVENTS_ARGUMENTS="$TEST_DIR/arguments"
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
    'cloudformation describe-stack-resource') printf '%s\n' "${RESOLVED_TABLE-events-test}" ;;
    *) exit 99 ;;
esac
MOCK
cat >"$TEST_DIR/work/zig-out/bin/events" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$EVENTS_TABLE_NAME|$AWS_REGION|$AWS_PROFILE|$AWS_EC2_METADATA_DISABLED"
printf '%s\0' "$@" >"$EVENTS_ARGUMENTS"
if [ -n "${EVENTS_INPUT:-}" ]; then cat >"$EVENTS_INPUT"; fi
[ "$AWS_ACCESS_KEY_ID" = test-access ] && [ "$AWS_SECRET_ACCESS_KEY" = test-secret ] &&
    [ "$AWS_SESSION_TOKEN" = test-session ] || exit 98
exit "${EVENTS_EXIT:-0}"
MOCK
chmod +x "$TEST_DIR/bin/aws" "$TEST_DIR/work/zig-out/bin/events"
export PATH="$TEST_DIR/bin:$PATH"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail_test "missing expected text: $2" ;; esac; }

# Help must also work before a binary is built and with AWS discovery unavailable.
mv "$TEST_DIR/work/zig-out/bin/events" "$TEST_DIR/events-binary"
for args in '--help' 'create --help' 'read -h'; do
    output="$(FAIL_AWS=1 bash "$TEST_DIR/work/events.sh" $args)"
    contains "$output" 'events create'
done
[ ! -s "$AWS_CALLS" ] || fail_test 'help contacted AWS'
mv "$TEST_DIR/events-binary" "$TEST_DIR/work/zig-out/bin/events"

output="$(PROFILE=chosen-profile REGION=chosen-region STACK_NAME=chosen-stack \
    bash "$TEST_DIR/work/events.sh" read --tenant 'tenant with spaces' --event-id 00000000-0000-0000-0000-000000000001)"
contains "$output" 'events-test|chosen-region|chosen-profile|true'
contains "$(cat "$AWS_CALLS")" '--logical-resource-id SeatEventsTable'
contains "$(cat "$AWS_CALLS")" '--stack-name chosen-stack'
contains "$(cat "$AWS_CALLS")" '--region chosen-region'
contains "$(cat "$AWS_CALLS")" '--profile chosen-profile'
python3 - "$EVENTS_ARGUMENTS" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes().split(b'\0') == [b'read', b'--tenant', b'tenant with spaces', b'--event-id', b'00000000-0000-0000-0000-000000000001', b'']
PY

output="$(bash "$TEST_DIR/work/events.sh" --profile override --region=override-region --stack-name override-stack create --tenant t --event-id 00000000-0000-0000-0000-000000000001)"
contains "$output" 'events-test|override-region|override|true'
contains "$(cat "$AWS_CALLS")" '--stack-name override-stack'

export EVENTS_INPUT="$TEST_DIR/input"
printf '%s\n' '{"tenant":"tenant-a","tag":"quote\" and slash\\"}' >"$TEST_DIR/expected-input"
bash "$TEST_DIR/work/events.sh" create --tenant tenant-a --event-id 00000000-0000-0000-0000-000000000001 \
    <"$TEST_DIR/expected-input" >/dev/null
cmp "$EVENTS_INPUT" "$TEST_DIR/expected-input" || fail_test 'stdin changed while forwarding'
unset EVENTS_INPUT

for table in '' None; do
    if output="$(RESOLVED_TABLE="$table" bash "$TEST_DIR/work/events.sh" read 2>&1)"; then
        fail_test 'missing SeatEventsTable accepted'
    fi
    contains "$output" 'SeatEventsTable'
done
if output="$(FAIL_AWS=1 bash "$TEST_DIR/work/events.sh" read 2>&1)"; then fail_test 'AWS error accepted'; fi
case "$output" in *sensitive*) fail_test 'upstream diagnostic leaked' ;; esac
if EVENTS_EXIT=2 bash "$TEST_DIR/work/events.sh" read >/dev/null; then fail_test 'binary failure hidden'; fi
: >"$AWS_CALLS"
if bash "$TEST_DIR/work/events.sh" delete-all >/dev/null 2>&1; then fail_test 'delete-all accepted'; fi
[ ! -s "$AWS_CALLS" ] || fail_test 'forbidden command contacted AWS'
printf 'PASS: Events wrapper regression tests\n'
