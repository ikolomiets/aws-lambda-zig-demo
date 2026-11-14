#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail_test "missing: $2" ;; esac; }
absent() { case "$1" in *"$2"*) fail_test "unexpected: $2" ;; esac; }
api="$(sed -n '/^  OperationsApi:/,/^  [A-Za-z]/p' "$REPOSITORY_ROOT/template.yaml" | sed '$d')"
contains "$api" 'Type: AWS::Serverless::HttpApi'
contains "$api" 'StageName: $default'
contains "$api" 'DisableExecuteApiEndpoint: false'
contains "$api" '/operations:'
contains "$api" '/operations/{id}:'
contains "$api" 'post:'
contains "$api" 'get:'
contains "$api" '${IntakeFunction.Arn}/invocations'
contains "$api" '${QueryFunction.Arn}/invocations'
[ "$(printf '%s\n' "$api" | grep -c 'payloadFormatVersion: "2.0"')" -eq 2 ] || fail_test 'expected two payload 2.0 integrations'
[ "$(printf '%s\n' "$api" | grep -c '^          /')" -eq 2 ] || fail_test 'expected exactly two route paths'
[ "$(printf '%s\n' "$api" | grep -c 'type: aws_proxy')" -eq 2 ] || fail_test 'expected two proxy integrations'
[ "$(printf '%s\n' "$api" | grep -Ec '^            [a-z-]+:')" -eq 2 ] || fail_test 'expected exactly two route methods'
absent "$api" 'Cors'
absent "$api" 'cors'
absent "$api" '$default:'
absent "$api" 'x-amazon-apigateway-any-method'
absent "$api" 'Auth:'
absent "$api" 'security:'
absent "$api" 'DefaultRouteSettings:'
for setting in \
    'SubmissionThrottlingRateLimit 10' 'SubmissionThrottlingBurstLimit 20' \
    'QueryThrottlingRateLimit 50' 'QueryThrottlingBurstLimit 100'
do
    read -r parameter default <<<"$setting"
    declaration="$(sed -n "/^  $parameter:/,/^  [A-Za-z]/p" "$REPOSITORY_ROOT/template.yaml" | sed '$d')"
    contains "$declaration" 'Type: Number'
    contains "$declaration" "Default: $default"
    contains "$declaration" 'MinValue: 0'
done
settings="$(sed -n '/^      RouteSettings:/,/^      [A-Za-z]/p' <<<"$api" | sed '$d')"
[ "$(printf '%s\n' "$settings" | grep -c '^        "')" -eq 2 ] || fail_test 'expected two route throttle settings'
submission="$(sed -n '/^        "POST \/operations":/,/^        "GET /p' <<<"$settings" | sed '$d')"
query="$(sed -n '/^        "GET \/operations\/{id}":/,$p' <<<"$settings")"
contains "$submission" 'ThrottlingRateLimit: !Ref SubmissionThrottlingRateLimit'
contains "$submission" 'ThrottlingBurstLimit: !Ref SubmissionThrottlingBurstLimit'
contains "$query" 'ThrottlingRateLimit: !Ref QueryThrottlingRateLimit'
contains "$query" 'ThrottlingBurstLimit: !Ref QueryThrottlingBurstLimit'
for pair in 'IntakeApiPermission IntakeFunction POST/operations' 'QueryApiPermission QueryFunction GET/operations/*'; do
    read -r permission function route <<<"$pair"
    grant="$(sed -n "/^  $permission:/,/^  [A-Za-z]/p" "$REPOSITORY_ROOT/template.yaml" | sed '$d')"
    contains "$grant" 'Action: lambda:InvokeFunction'
    contains "$grant" 'Principal: apigateway.amazonaws.com'
    contains "$grant" "FunctionName: !Ref $function"
    contains "$grant" "\${OperationsApi}/\$default/$route"
done
output="$(sed -n '/^Outputs:/,$p' "$REPOSITORY_ROOT/template.yaml")"
contains "$output" 'OperationsApiUrl:'
contains "$output" 'https://${OperationsApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}'
absent "$(cat "$REPOSITORY_ROOT/template.yaml")" 'FunctionUrl'
absent "$(cat "$REPOSITORY_ROOT/template.yaml")" 'AWS::Lambda::Url'
printf 'Operations API configuration tests passed.\n'

# Exercise discovery and public probe semantics with no AWS credentials or sockets.
source "$REPOSITORY_ROOT/deploy.sh"
defaults="$(env -u SUBMISSION_THROTTLING_RATE_LIMIT -u SUBMISSION_THROTTLING_BURST_LIMIT \
    -u QUERY_THROTTLING_RATE_LIMIT -u QUERY_THROTTLING_BURST_LIMIT \
    bash -c 'source "$1/deploy.sh"; build_sam_parameter_overrides; printf "%s\n" "${SAM_PARAMETER_OVERRIDES[@]}"' \
    bash "$REPOSITORY_ROOT")"
for expected in SubmissionThrottlingRateLimit=10 SubmissionThrottlingBurstLimit=20 \
    QueryThrottlingRateLimit=50 QueryThrottlingBurstLimit=100
do
    contains "$defaults" "$expected"
done
deployment_parameters() (
    source "$REPOSITORY_ROOT/deploy.sh"
    parse_deployment_options --stack-name throttle-fixture --profile throttle-profile \
        --region us-west-2 "$@"
    validate_route_throttles
    DEPLOYMENT_PARAMETER_OVERRIDES=("EnableWireGuardGateway=true" "VpcId=vpc-00000001")
    build_sam_parameter_overrides
    printf '%s\n' "${SAM_PARAMETER_OVERRIDES[@]}"
    printf 'selection: %s %s %s\n' "$STACK_NAME" "$PROFILE" "$REGION"
)
overrides="$(SUBMISSION_THROTTLING_RATE_LIMIT=11.5 SUBMISSION_THROTTLING_BURST_LIMIT=22 \
    QUERY_THROTTLING_RATE_LIMIT=60.25 QUERY_THROTTLING_BURST_LIMIT=120 deployment_parameters)"
for expected in SubmissionThrottlingRateLimit=11.5 SubmissionThrottlingBurstLimit=22 \
    QueryThrottlingRateLimit=60.25 QueryThrottlingBurstLimit=120
do
    contains "$overrides" "$expected"
done
overrides="$(SUBMISSION_THROTTLING_RATE_LIMIT=11.5 SUBMISSION_THROTTLING_BURST_LIMIT=22 \
    QUERY_THROTTLING_RATE_LIMIT=60.25 QUERY_THROTTLING_BURST_LIMIT=120 deployment_parameters \
    --submission-throttling-rate-limit 12.5 --submission-throttling-burst-limit=30 \
    --query-throttling-rate-limit=75.25 --query-throttling-burst-limit 150)"
for expected in SubmissionThrottlingRateLimit=12.5 SubmissionThrottlingBurstLimit=30 \
    QueryThrottlingRateLimit=75.25 QueryThrottlingBurstLimit=150 \
    EnableWireGuardGateway=true VpcId=vpc-00000001 'selection: throttle-fixture throttle-profile us-west-2'
do
    contains "$overrides" "$expected"
done
for option in submission-throttling-rate-limit submission-throttling-burst-limit \
    query-throttling-rate-limit query-throttling-burst-limit
do
    for mode in --dev --cleanup; do
        if output="$(deployment_parameters "$mode" "--$option" 1 2>&1)"; then
            fail_test "accepted --$option in $mode mode"
        fi
        if [ "$mode" = --dev ]; then
            contains "$output" 'requires a full deployment'
        else
            contains "$output" 'accepts only profile, region, and stack selection'
        fi
    done
done
for option in submission-throttling-rate-limit query-throttling-rate-limit; do
    for invalid in -1 NaN '' 1e2; do
        if output="$(bash "$REPOSITORY_ROOT/deploy.sh" --dry-run "--$option=$invalid" 2>&1)"; then
            fail_test "accepted invalid rate: $invalid"
        fi
        if [ -n "$invalid" ]; then contains "$output" 'nonnegative decimal'; else contains "$output" 'empty value'; fi
    done
done
for option in submission-throttling-burst-limit query-throttling-burst-limit; do
    for invalid in -1 1.5 NaN ''; do
        if output="$(bash "$REPOSITORY_ROOT/deploy.sh" --dry-run "--$option=$invalid" 2>&1)"; then
            fail_test "accepted invalid burst: $invalid"
        fi
        if [ -n "$invalid" ]; then contains "$output" 'nonnegative integer'; else contains "$output" 'empty value'; fi
    done
done
for variable in SUBMISSION_THROTTLING_RATE_LIMIT SUBMISSION_THROTTLING_BURST_LIMIT \
    QUERY_THROTTLING_RATE_LIMIT QUERY_THROTTLING_BURST_LIMIT
do
    if output="$(env "$variable=" bash "$REPOSITORY_ROOT/deploy.sh" --dry-run 2>&1)"; then
        fail_test "accepted empty $variable"
    fi
    contains "$output" "$variable must be a nonnegative"
done
overrides="$(deployment_parameters --submission-throttling-rate-limit 0 --submission-throttling-burst-limit 0 \
    --query-throttling-rate-limit 0 --query-throttling-burst-limit 0)"
contains "$overrides" 'SubmissionThrottlingRateLimit=0'
contains "$overrides" 'QueryThrottlingBurstLimit=0'
printf 'Operations API deployment parameter tests passed.\n'
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/operations-api-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/zig-out/bin"
printf '#!/usr/bin/env bash\nprintf "fixture-token\\n"\n' >"$TEST_DIR/zig-out/bin/paseto"
chmod +x "$TEST_DIR/zig-out/bin/paseto"
aws() {
    contains "$*" OperationsApiUrl
    absent "$*" IntakeFunctionUrl
    absent "$*" QueryFunctionUrl
    printf '%s\n' "${MOCK_ORIGIN:-https://operations.invalid/}"
}
STACK_NAME=fixture REGION=ca-central-1
resolve_operations_api_url
[ "$OPERATIONS_API_URL" = https://operations.invalid/ ] || fail_test 'wrong common origin'
for origin in None http://operations.invalid/ https://operations.invalid/prefix https://user@operations.invalid/ 'https://operations.invalid/?query'; do
    if (MOCK_ORIGIN="$origin" resolve_operations_api_url) >/dev/null 2>&1; then fail_test "accepted invalid origin: $origin"; fi
done
curl() {
    local method=GET token='' body='' url=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -X) method="$2"; shift ;;
            -H) token="$2"; shift ;;
            --data-binary) body="$2"; shift ;;
            -o|-w) shift ;;
            https://*) url="$1" ;;
        esac
        shift
    done
    printf '%s %s %s\n' "$method" "$url" "$body" >>"$TEST_DIR/probes"
    case "$method $url" in
        'POST https://operations.invalid/operations')
            if [ -z "$token" ]; then printf 401; else printf 400; fi ;;
        'GET https://operations.invalid/operations/00000000-0000-4000-8000-000000000000')
            if [ -z "$token" ]; then printf 401; else printf 404; fi ;;
        *) printf 404 ;;
    esac
}
(cd "$TEST_DIR"; check_operations_api)
probes="$(cat "$TEST_DIR/probes")"
[ "$(wc -l <"$TEST_DIR/probes" | tr -d ' ')" = 9 ] || fail_test 'missing API probe'
contains "$probes" 'POST https://operations.invalid/operations {}'
contains "$probes" 'GET https://operations.invalid/unsupported'
contains "$probes" 'POST https://operations.invalid/operations/00000000-0000-4000-8000-000000000000'
# A gateway-shaped response on a matching route must fail the authentication check.
curl() { printf 404; }
if (cd "$TEST_DIR"; check_operations_api) >/dev/null 2>&1; then fail_test 'accepted unmatched-route response as authentication evidence'; fi
printf 'Operations API discovery and probe tests passed.\n'
