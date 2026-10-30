#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/events-wrapper-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/repo/zig-out/bin" "$TEST_DIR/bin"
cp "$REPOSITORY_ROOT/events.sh" "$TEST_DIR/repo/"
while IFS= read -r key; do unset "$key"; done < <(compgen -e | sed -n '/^AWS_/p')
unset PROFILE REGION STACK_NAME PASETO_TOKEN PASETO_FOREIGN_TOKEN PASETO_PRIVATE_KEY
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export PATH="$TEST_DIR/bin:$PATH" AWS_CALLS="$TEST_DIR/aws-calls" REQUEST_FILE="$TEST_DIR/request"
export EVENT_ID=00000000-0000-0000-0000-000000000001
: >"$AWS_CALLS"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail_test "missing: $2" ;; esac; }
run_events() { bash "$TEST_DIR/repo/events.sh" "$@"; }
reject() {
    : >"$AWS_CALLS"
    if run_events "$@" >"$TEST_DIR/output" 2>&1; then fail_test 'accepted invalid arguments'; fi
    [ ! -s "$AWS_CALLS" ] || fail_test 'invalid arguments contacted AWS'
}

cat >"$TEST_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${PASETO_TOKEN:-}${PASETO_FOREIGN_TOKEN:-}${PASETO_PRIVATE_KEY:-}" ] || exit 90
printf '%s | profile=%s region=%s\n' "$*" "${AWS_PROFILE:-}" "${AWS_REGION:-}" >>"$AWS_CALLS"
[ "${AWS_REGION:-}" = "${EXPECTED_REGION:-ca-central-1}" ] || exit 91
[ "${AWS_DEFAULT_REGION:-}" = "$AWS_REGION" ] || exit 92
case "$1 $2" in
    'configure export-credentials')
        [ "${AWS_ACCESS_KEY_ID:-}" = "${EXPECTED_ACCESS_KEY:-}" ] || exit 93
        [ "${AWS_SESSION_TOKEN:-}" = "${EXPECTED_SESSION_TOKEN:-}" ] || exit 94
        if [ "${BAD_CREDENTIALS:-false}" = true ]; then printf '{}\n'; exit; fi
        if [ "${STATIC_CREDENTIALS:-false}" = true ]; then
            printf '%s\n' '{"AccessKeyId":"fixture-access","SecretAccessKey":"fixture-secret"}'
        else
            printf '%s\n' '{"AccessKeyId":"fixture-access","SecretAccessKey":"fixture-secret","SessionToken":"fixture-session"}'
        fi ;;
    'cloudformation describe-stack-resource') printf 'fixture-events\n' ;;
    'cloudformation describe-stacks') printf '%s\n' "${INTAKE_URL:-https://intake.invalid/}" ;;
    *) exit 95 ;;
esac
MOCK
cat >"$TEST_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = '--disable --config -' ] || exit 90
[ -z "${PASETO_TOKEN:-}${PASETO_FOREIGN_TOKEN:-}${PASETO_PRIVATE_KEY:-}" ] || exit 91
config="$(cat)"
url="$(printf '%s\n' "$config" | sed -n 's/^url = //p' | jq -r .)"
[ "$url" = https://intake.invalid/ ] || exit 92
header="$(printf '%s\n' "$config" | sed -n '/^header = .*Authorization:/s/^header = //p' | jq -r .)"
[ "$header" = 'Authorization: Bearer v4.public.fixture' ] || exit 93
printf '%s\n' "$config" | sed -n 's/^data = //p' | jq -r . >"$REQUEST_FILE"
if [ "${CURL_FAILURE:-false}" = true ]; then exit 7; fi
if [ "${BAD_RESPONSE:-false}" = true ]; then printf '{}\n200\n'; exit; fi
jq -c '{id:.id,name:.name,tenant:"fixture-owner",state:"SUBMITTED"}' "$REQUEST_FILE"
printf '%s\n' "${HTTP_STATUS:-200}"
MOCK
chmod +x "$TEST_DIR/bin/aws" "$TEST_DIR/bin/curl"

# Help and bad invocations require no credentials, binary, or cloud discovery.
for args in help create read; do
    if [ "$args" = help ]; then run_events --help >/dev/null
    else run_events "$args" --help >/dev/null; fi
done
[ ! -s "$AWS_CALLS" ] || fail_test 'help contacted AWS'
reject create
reject create --class general=3
export PASETO_TOKEN=v4.public.fixture
for class in general general=0 general=-1 general=1.5 general=4294967296 capacity=1 allocation=1 '=1'; do
    reject create --class "$class"
done
reject create --class general=3 --class general=4
reject create --class general=3 --timeout-seconds=0
reject create --class general=3 --event-id=bad
reject create --class general=3 --tenant=override
reject --profile= create --class general=3
reject --region --stack-name stack create --class general=3
reject read --event-id "$EVENT_ID"

# Creation has no host-binary prerequisite and uses explicit classes, with no stdin.
output="$(run_events create --class general=100 --class premium=25 --event-id "$EVENT_ID" </dev/null)"
printf '%s' "$output" | jq -e --arg id "$EVENT_ID" \
    '.id == $id and .tenant == "fixture-owner" and .state == "SUBMITTED"' >/dev/null
jq -e --arg id "$EVENT_ID" '. == {id:$id,name:"SeatReservation",body:{command:"create_event",
    classes:{general:100,premium:25},timeout_seconds:300}}' "$REQUEST_FILE" >/dev/null
calls="$(cat "$AWS_CALLS")"
contains "$calls" 'configure export-credentials --format process'
contains "$calls" 'profile= region=ca-central-1'
case "$calls" in *--profile*) fail_test 'default chain forced a profile' ;; esac

output="$(run_events create --class='A=B=7' --class='é=2' --timeout-seconds=600)"
jq -e '.body.classes == {"A=B":7,"é":2} and .body.timeout_seconds == 600 and
    (.id|test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))' \
    "$REQUEST_FILE" >/dev/null

cat >"$TEST_DIR/repo/zig-out/bin/events" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 5 ] && [ "$1" = read ] && [ "$2" = --tenant ] &&
    [ "$3" = "${EXPECTED_TENANT:-fixture-owner}" ] && [ "$4" = --event-id ] &&
    [ "$5" = "$EVENT_ID" ] || exit 90
[ "$EVENTS_TABLE_NAME" = fixture-events ] || exit 91
[ "$AWS_ACCESS_KEY_ID" = fixture-access ] && [ "$AWS_SECRET_ACCESS_KEY" = fixture-secret ] || exit 92
if [ "${STATIC_CREDENTIALS:-false}" = true ]; then
    [ -z "${AWS_SESSION_TOKEN:-}" ] || exit 93
else
    [ "$AWS_SESSION_TOKEN" = fixture-session ] || exit 94
fi
[ -z "${PASETO_TOKEN:-}${PASETO_PRIVATE_KEY:-}" ] || exit 95
printf '{"state":"ready"}\n'
MOCK
chmod +x "$TEST_DIR/repo/zig-out/bin/events"

# Reads require an explicit tenant even when a token contains a usable subject.
token_with_subject="v4.public.$(jq -nr '{sub:"token-owner"} | tojson + ("0" * 64) |
    @base64 | gsub("[+]";"-") | gsub("/";"_") | sub("=+$";"")')"
for token in '' malformed "$token_with_subject"; do
    PASETO_TOKEN="$token" reject read --event-id "$EVENT_ID"
    contains "$(cat "$TEST_DIR/output")" 'read requires --tenant and --event-id'
    PASETO_TOKEN="$token" EXPECTED_TENANT=explicit-owner \
        run_events read --event-id "$EVENT_ID" --tenant explicit-owner >/dev/null
done
reject read --tenant explicit-owner
reject read --tenant= --event-id "$EVENT_ID"
# Explicit tenant arguments preserve exact Unicode and whitespace.
for tenant in 'é-tenant' $' tenant\n'; do
    EXPECTED_TENANT="$tenant" run_events read --tenant "$tenant" --event-id "$EVENT_ID" >/dev/null
done

# Environment selectors follow the scenario runner's precedence without forcing --profile.
for source in aws default legacy; do
    : >"$AWS_CALLS"
    (
        export PROFILE=legacy REGION=legacy-region EXPECTED_REGION=legacy-region
        case "$source" in
            aws) export AWS_PROFILE=selected AWS_DEFAULT_PROFILE=ignored AWS_REGION=selected-region
                 export AWS_DEFAULT_REGION=ignored EXPECTED_REGION=selected-region ;;
            default) export AWS_DEFAULT_PROFILE=selected AWS_DEFAULT_REGION=selected-region
                     export EXPECTED_REGION=selected-region ;;
        esac
        export AWS_ACCESS_KEY_ID=inherited AWS_SECRET_ACCESS_KEY=inherited-secret AWS_SESSION_TOKEN=old-session
        export EXPECTED_ACCESS_KEY=inherited EXPECTED_SESSION_TOKEN=old-session
        run_events read --tenant fixture-owner --event-id "$EVENT_ID" >/dev/null
    )
    calls="$(cat "$AWS_CALLS")"
    if [ "$source" = legacy ]; then contains "$calls" 'profile=legacy region=legacy-region'
    else contains "$calls" 'profile=selected region=selected-region'; fi
    case "$calls" in *--profile*) fail_test 'inherited profile overrode environment credentials' ;; esac
done

: >"$AWS_CALLS"
AWS_PROFILE=ignored AWS_REGION=ignored EXPECTED_REGION=cli-region STATIC_CREDENTIALS=true \
    run_events --profile=cli-profile --region cli-region --stack-name cli-stack \
    read --tenant=fixture-owner --event-id="$EVENT_ID" >/dev/null
calls="$(cat "$AWS_CALLS")"
contains "$calls" '--profile cli-profile'
contains "$calls" '--stack-name cli-stack'
contains "$calls" 'profile=cli-profile region=cli-region'

for fault in BAD_CREDENTIALS CURL_FAILURE BAD_RESPONSE; do
    if output="$(env "$fault=true" bash "$TEST_DIR/repo/events.sh" create \
        --class general=3 --event-id "$EVENT_ID" 2>&1)"; then fail_test "accepted $fault"; fi
    case "$output" in *v4.public.fixture*|*fixture-secret*) fail_test 'failure disclosed credentials' ;; esac
done
if output="$(HTTP_STATUS=401 run_events create --class general=3 --event-id "$EVENT_ID" 2>&1)"; then
    fail_test 'accepted rejected token'
fi
contains "$output" 'HTTP 401'
printf 'PASS: Events wrapper regression tests\n'
