#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lambda-logs-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/work"
cp "$REPOSITORY_ROOT/lambda_logs.sh" "$TEST_DIR/work/"
export LOG_CALLS="$TEST_DIR/calls"
cat >"$TEST_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG_CALLS"
case "$1 $2" in
    'cloudformation describe-stacks') printf '%s\n' "$RESOLVED_NAME" ;;
    'logs filter-log-events')
        printf '[{"timestamp":1000,"eventId":"one","message":"seat log"}]\n'
        ;;
    *) exit 99 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/aws"
export PATH="$TEST_DIR/bin:$PATH"
for selection in seat-reservation-processor seat-reservation-completion-processor; do
    case "$selection" in
        seat-reservation-processor) output_key=SeatReservationProcessorName ;;
        *) output_key=SeatReservationCompletionProcessorName ;;
    esac
    export RESOLVED_NAME="$selection-custom"
    : >"$LOG_CALLS"
    bash "$TEST_DIR/work/lambda_logs.sh" "$selection" >/dev/null
    calls="$(cat "$LOG_CALLS")"
    case "$calls" in *"OutputKey=='$output_key'"*) ;; *) exit 1 ;; esac
    case "$calls" in *"--log-group-name /aws/lambda/$RESOLVED_NAME"*) ;; *) exit 1 ;; esac
    [ "$(cat "$TEST_DIR/work/$RESOLVED_NAME.log")" = '1970-01-01T00:00:01.000 seat log' ]
done
printf 'PASS: seat Lambda log selection tests\n'
