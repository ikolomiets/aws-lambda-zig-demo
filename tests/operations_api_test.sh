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
