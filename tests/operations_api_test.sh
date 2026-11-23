#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail_test "missing: $2" ;; esac; }
absent() { case "$1" in *"$2"*) fail_test "unexpected: $2" ;; esac; }
contains_line() { grep -Fxq "$2" <<<"$1" || fail_test "missing line: $2"; }

route_definition() {
    awk -v route="          $2:" '
        $0 == route || $0 == route " !If" { found = 1; next }
        found && $0 !~ /^           / && $0 !~ /^ *$/ { exit }
        found { print }
    ' <<<"$1"
}

assert_route_integrations() {
    local definition route method function
    for definition in '/operations post IntakeFunction' '/operations/{id} get QueryFunction'; do
        read -r route method function <<<"$definition"
        definition="$(route_definition "$1" "$route")"
        contains_line "$definition" "            $method:"
        [ "$(grep -Ec '^            [a-z-]+:' <<<"$definition")" -eq 1 ] ||
            fail_test "expected one method for $route"
        contains_line "$definition" '              x-amazon-apigateway-integration:'
        contains_line "$definition" '                type: aws_proxy'
        contains_line "$definition" '                payloadFormatVersion: "2.0"'
        contains_line "$definition" "                uri: !Sub arn:\${AWS::Partition}:apigateway:\${AWS::Region}:lambda:path/2015-03-31/functions/\${$function.Arn}/invocations"
        [ "$(grep -c 'payloadFormatVersion:' <<<"$definition")" -eq 1 ] ||
            fail_test "expected one payload format for $route"
        [ "$(grep -c '^[[:space:]]*uri:' <<<"$definition")" -eq 1 ] ||
            fail_test "expected one integration URI for $route"
    done
}

api="$(sed -n '/^  OperationsApi:/,/^  [A-Za-z]/p' "$REPOSITORY_ROOT/template.yaml" | sed '$d')"
contains "$api" 'Type: AWS::Serverless::HttpApi'
contains "$api" 'StageName: $default'
contains "$api" 'DisableExecuteApiEndpoint: false'
assert_route_integrations "$api"
contains_line "$(route_definition "$api" /auth/github/device/start)" '            - post:'
# Negative fixtures must fail the same assertions used for the real template.
swapped="${api//IntakeFunction.Arn/TemporaryFunction.Arn}"
swapped="${swapped//QueryFunction.Arn/IntakeFunction.Arn}"
swapped="${swapped//TemporaryFunction.Arn/QueryFunction.Arn}"
if (assert_route_integrations "$swapped") >/dev/null 2>&1; then
    fail_test 'swapped Lambda integrations passed route checks'
fi
wrong_version="${api/payloadFormatVersion: \"2.0\"/payloadFormatVersion: \"1.0\"}"
if (assert_route_integrations "$wrong_version") >/dev/null 2>&1; then
    fail_test 'incorrect route payload version passed route checks'
fi
wrong_method="${api/            post:/            put:}"
if (assert_route_integrations "$wrong_method") >/dev/null 2>&1; then
    fail_test 'incorrect route method passed route checks'
fi
[ "$(printf '%s\n' "$api" | grep -c 'payloadFormatVersion: "2.0"')" -eq 8 ] || fail_test 'expected eight payload 2.0 integrations'
[ "$(printf '%s\n' "$api" | grep -c '^          /')" -eq 8 ] || fail_test 'expected two base paths and six conditional paths'
[ "$(printf '%s\n' "$api" | grep -c 'type: aws_proxy')" -eq 8 ] || fail_test 'expected eight proxy integrations'
[ "$(printf '%s\n' "$api" | grep -Ec '^            [a-z-]+:')" -eq 2 ] || fail_test 'expected exactly two route methods'
absent "$api" '$default:'
absent "$api" 'x-amazon-apigateway-any-method'
absent "$api" 'Auth:'
absent "$api" 'security:'
absent "$api" 'DefaultRouteSettings:'

template="$REPOSITORY_ROOT/template.yaml"
template_section() {
    sed -n "/^  $1:/,/^  [A-Za-z]/p" "$template" | sed '$d'
}
contains_line "$(template_section EnableGitHubExchange)" '    Default: "false"'
contains_line "$(cat "$template")" '  GitHubExchangeEnabled: !Equals [!Ref EnableGitHubExchange, "true"]'
required="$(template_section GitHubExchangeInputsRequired)"
contains_line "$required" '    RuleCondition: !Equals [!Ref EnableGitHubExchange, "true"]'
for parameter in GitHubClientId GitHubClientSecretArn PasetoSigningKeySecretArn; do
    contains_line "$(template_section "$parameter")" '    Default: ""'
    contains_line "$required" "      - Assert: !Not [!Equals [!Ref $parameter, \"\"]]"
done
auth_routes=(
    'post /auth/github/exchange AuthenticationApiPermission'
    'post /auth/github/device/start AuthenticationDeviceStartApiPermission'
    'post /auth/github/device/poll AuthenticationDevicePollApiPermission'
    'get /auth/github/authorize AuthenticationAuthorizeApiPermission'
    'get /auth/github/callback AuthenticationCallbackApiPermission'
    'post /auth/github/redeem AuthenticationRedeemApiPermission'
)
expected_auth_route="$(cat <<'YAML'
            - GitHubExchangeEnabled
            - post:
                responses: {}
                x-amazon-apigateway-integration:
                  type: aws_proxy
                  httpMethod: POST
                  payloadFormatVersion: "2.0"
                  uri: !Sub arn:${AWS::Partition}:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${AuthenticationFunction.Arn}/invocations
            - !Ref AWS::NoValue
YAML
)"
source_arn='arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${OperationsApi}/$default'
for auth_route in "${auth_routes[@]}"; do
    read -r method path permission <<<"$auth_route"
    contains_line "$api" "          $path: !If"
    [ "$(route_definition "$api" "$path" | sed '/^$/d')" = "${expected_auth_route/- post:/- $method:}" ] ||
        fail_test "$path must add only $method when enabled and omit the path when disabled"
    grant="$(template_section "$permission")"
    contains_line "$grant" '    Type: AWS::Lambda::Permission'
    contains_line "$grant" '    Condition: GitHubExchangeEnabled'
    contains_line "$grant" '      FunctionName: !Ref AuthenticationFunction'
    contains_line "$grant" '      Action: lambda:InvokeFunction'
    contains_line "$grant" '      Principal: apigateway.amazonaws.com'
    contains_line "$grant" '      SourceAccount: !Ref AWS::AccountId'
    case "$method" in get) method=GET ;; post) method=POST ;; esac
    contains_line "$grant" "      SourceArn: !Sub $source_arn/$method$path"
done
[ "$(grep -Fc 'FunctionName: !Ref AuthenticationFunction' "$template")" -eq 6 ] ||
    fail_test 'expected exactly six invocation grants for authentication'

cors_condition="$(sed -n '/^  OperationsBrowserCorsEnabled:/,/^  [A-Za-z]/p' "$template" | sed '$d')"
expected_cors_condition="$(cat <<'YAML'
  OperationsBrowserCorsEnabled: !And
    - !Condition GitHubExchangeEnabled
    - !Not [!Equals [!Ref OperationsBrowserOrigins, ""]]
YAML
)"
[ "$cors_condition" = "$expected_cors_condition" ] ||
    fail_test 'CORS must require enabled GitHub sign-in and configured origins'
contains_line "$(template_section OperationsBrowserOrigins)" '    Default: ""'
expected_cors="$(cat <<'YAML'
        x-amazon-apigateway-cors: !If
          - OperationsBrowserCorsEnabled
          - allowOrigins: !Split [",", !Ref OperationsBrowserOrigins]
            allowMethods: [GET, POST, OPTIONS]
            allowHeaders: [Authorization, Content-Type]
            exposeHeaders: [Retry-After]
          - !Ref AWS::NoValue
YAML
)"
cors="$(sed -n '/^        x-amazon-apigateway-cors:/,/^        paths:/p' <<<"$api" | sed '$d')"
[ "$cors" = "$expected_cors" ] || fail_test 'gateway CORS policy differs'

contains_line "$(template_section PendingSignInTable)" '    Type: AWS::DynamoDB::Table'
contains_line "$(template_section PendingSignInTable)" '    Condition: GitHubExchangeEnabled'
contains_line "$(template_section PendingSignInTable)" '    DeletionPolicy: Delete'
expected_table="$(cat <<'YAML'
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: id
          AttributeType: S
      KeySchema:
        - AttributeName: id
          KeyType: HASH
      TimeToLiveSpecification:
        AttributeName: expires_at
        Enabled: true
YAML
)"
[ "$(template_section PendingSignInTable | sed -n '/^    Properties:/,$p' | sed '1d;/^$/d')" = "$expected_table" ] ||
    fail_test 'Pending Sign-in table key or TTL differs from the adapter'

auth_function="$(template_section AuthenticationFunction)"
contains_line "$auth_function" '    Type: AWS::Serverless::Function'
contains_line "$auth_function" '    Condition: GitHubExchangeEnabled'
contains_line "$auth_function" '      CodeUri: zig-out/packages/authentication-lambda.zip'
contains_line "$auth_function" '      Handler: bootstrap'
expected_auth_permissions="$(cat <<'YAML'
        - AWSLambdaBasicExecutionRole
        - Version: "2012-10-17"
          Statement:
            - Effect: Allow
              Action: secretsmanager:GetSecretValue
              Resource:
                - !Ref GitHubClientSecretArn
                - !Ref PasetoSigningKeySecretArn
            - Effect: Allow
              Action:
                - dynamodb:GetItem
                - dynamodb:PutItem
                - dynamodb:UpdateItem
              Resource: !GetAtt PendingSignInTable.Arn
YAML
)"
auth_permissions="$(sed -n '/^      Policies:/,/^      Environment:/p' <<<"$auth_function" | sed '1d;$d')"
[ "$auth_permissions" = "$expected_auth_permissions" ] || fail_test 'authentication role scope differs'
[ "$(grep -c 'secretsmanager:' "$template")" -eq 3 ] ||
    fail_test 'expected only the two ARN parameter patterns and the authentication role action'
expected_auth_environment="$(cat <<'YAML'
          GITHUB_CLIENT_ID: !Ref GitHubClientId
          GITHUB_CLIENT_SECRET_ARN: !Ref GitHubClientSecretArn
          GITHUB_OAUTH_CALLBACK_URL: !Ref GitHubOAuthCallbackUrl
          GITHUB_BROWSER_REDIRECT_URIS: !Ref GitHubBrowserRedirectUris
          PASETO_SIGNING_KEY_SECRET_ARN: !Ref PasetoSigningKeySecretArn
          PASETO_PUBLIC_KEY: !Ref PasetoPublicKey
          PENDING_SIGN_IN_TABLE_NAME: !Ref PendingSignInTable
YAML
)"
[ "$(sed -n '/^        Variables:/,$p' <<<"$auth_function" | sed '1d;/^$/d')" = "$expected_auth_environment" ] ||
    fail_test 'authentication environment must contain only the public configuration and secret references'
contains_line "$(template_section AuthenticationFunctionName)" '    Condition: GitHubExchangeEnabled'
contains_line "$(template_section AuthenticationFunctionName)" '    Value: !Ref AuthenticationFunction'
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
for pair in 'IntakeApiPermission IntakeFunction POST/operations' \
    'QueryApiPermission QueryFunction GET/operations/*'
do
    read -r permission function route <<<"$pair"
    grant="$(sed -n "/^  $permission:/,/^  [A-Za-z]/p" "$REPOSITORY_ROOT/template.yaml" | sed '$d')"
    contains "$grant" 'Action: lambda:InvokeFunction'
    contains "$grant" 'Principal: apigateway.amazonaws.com'
    contains "$grant" "FunctionName: !Ref $function"
    contains_line "$grant" "      SourceArn: !Sub $source_arn/$route"
done
output="$(sed -n '/^Outputs:/,$p' "$REPOSITORY_ROOT/template.yaml")"
contains "$output" 'OperationsApiUrl:'
contains "$output" 'https://${OperationsApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}'
absent "$(cat "$REPOSITORY_ROOT/template.yaml")" 'FunctionUrl'
absent "$(cat "$REPOSITORY_ROOT/template.yaml")" 'AWS::Lambda::Url'

# Check the access-log lifecycle and delivery grant without contacting AWS.
log_group="$(sed -n '/^  OperationsApiAccessLogGroup:/,/^  [A-Za-z]/p' "$REPOSITORY_ROOT/template.yaml" | sed '$d')"
contains "$log_group" 'Type: AWS::Logs::LogGroup'
contains "$log_group" 'RetentionInDays: 7'
contains "$log_group" 'DeletionPolicy: Delete'
contains "$log_group" 'UpdateReplacePolicy: Delete'
contains "$api" 'DestinationArn: !GetAtt OperationsApiAccessLogGroup.Arn'
contains "$api" 'DependsOn: OperationsApiAccessLogPolicy'
log_policy="$(sed -n '/^  OperationsApiAccessLogPolicy:/,/^  [A-Za-z]/p' "$REPOSITORY_ROOT/template.yaml" | sed '$d')"
contains "$log_policy" 'Type: AWS::Logs::ResourcePolicy'
contains "$log_policy" 'PolicyName: !Sub'
contains "$log_policy" 'DeletionPolicy: Delete'
policy_document="$(sed -n '/^      PolicyDocument: !Sub |/,/^      [A-Za-z]/p' <<<"$log_policy" | sed '1d; /^      [A-Za-z]/d')"
jq -se 'length == 1 and (.[0] |
    .Version == "2012-10-17" and (.Statement | length) == 1 and
    (.Statement[0] |
        .Effect == "Allow" and
        .Principal == {"Service": "delivery.logs.amazonaws.com"} and
        (.Action | sort) == ["logs:CreateLogStream", "logs:PutLogEvents"] and
        .Resource == "${OperationsApiAccessLogGroup.Arn}" and
        .Condition == {
            "StringEquals": {"aws:SourceAccount": "${AWS::AccountId}"},
            "ArnLike": {"aws:SourceArn": "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:*"}
        }))
' <<<"$policy_document" >/dev/null || fail_test 'access-log delivery grant is missing or too broad'

log_format="$(sed -n "s/^        Format: '\(.*\)'$/\1/p" <<<"$api")"
# An exact field allowlist excludes raw paths, credentials, bodies, query strings,
# IP addresses, and extra identity/business data. All substitutions are strings.
jq -se 'length == 1 and .[0] == {
    "request_id": "$context.requestId",
    "integration_request_id": "$context.integration.requestId",
    "route_key": "$context.routeKey",
    "status": "$context.status",
    "response_latency_ms": "$context.responseLatency",
    "integration_latency_ms": "$context.integration.latency"
}' <<<"$log_format" >/dev/null || fail_test 'unexpected access-log fields or unsafe substitutions'
# Substitute into the raw format before parsing, as the gateway does. Missing
# values below are representative inputs, not promises about AWS placeholders.
for scenario in success unauthorized throttled unmatched; do
    for missing in '-' '' 'unavailable' 'null'; do
        jq -en --arg format "$log_format" --arg scenario "$scenario" --arg missing "$missing" '
            (if $scenario == "success" then
                {request_id: "gateway-success", integration_request_id: "lambda-success",
                 route_key: "GET /operations/{id}", status: "200",
                 response_latency_ms: "12", integration_latency_ms: "10"}
             elif $scenario == "unauthorized" then
                {request_id: "gateway-unauthorized", integration_request_id: "lambda-unauthorized",
                 route_key: "POST /operations", status: "401",
                 response_latency_ms: "8", integration_latency_ms: "5"}
             else
                {request_id: "gateway-rejected", integration_request_id: $missing,
                 route_key: (if $scenario == "throttled" then "POST /operations" else $missing end),
                 status: (if $scenario == "throttled" then "429" else "404" end),
                 response_latency_ms: "2", integration_latency_ms: $missing}
             end) as $expected |
            {
                "$context.requestId": $expected.request_id,
                "$context.integration.requestId": $expected.integration_request_id,
                "$context.routeKey": $expected.route_key,
                "$context.status": $expected.status,
                "$context.responseLatency": $expected.response_latency_ms,
                "$context.integration.latency": $expected.integration_latency_ms
            } as $values |
            (reduce ($values | to_entries[]) as $entry
                ($format; split($entry.key) | join($entry.value)) | fromjson) == $expected
        ' >/dev/null || fail_test "invalid rendered access log for $scenario ($missing)"
    done
done
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
    validate_github_exchange_configuration
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

printf -v fixture_account '%012d' 0
fixture_secret_prefix="arn:aws:secretsmanager:us-west-2:$fixture_account:secret"
app_secret_arn="$fixture_secret_prefix:fixture-app-AbCd12"
signing_key_arn="$fixture_secret_prefix:fixture-key-DeFg34"
absent "$defaults" 'EnableGitHubExchange='
absent "$defaults" 'GitHubClientId='
overrides="$(GITHUB_CLIENT_ID=FixtureClient GITHUB_CLIENT_SECRET_ARN="$app_secret_arn" \
    PASETO_SIGNING_KEY_SECRET_ARN="$signing_key_arn" deployment_parameters --enable-github-exchange)"
contains_line "$overrides" 'EnableGitHubExchange=true'
contains_line "$overrides" 'GitHubClientId=FixtureClient'
contains_line "$overrides" "GitHubClientSecretArn=$app_secret_arn"
contains_line "$overrides" "PasetoSigningKeySecretArn=$signing_key_arn"
absent "$overrides" 'OperationsBrowserOrigins='
absent "$overrides" 'GitHubOAuthCallbackUrl='
absent "$overrides" 'GitHubBrowserRedirectUris'

managed_deployment_parameters() (
    export GITHUB_CLIENT_ID=FixtureClient GITHUB_CLIENT_SECRET_ARN="$app_secret_arn"
    export PASETO_SIGNING_KEY_SECRET_ARN="$signing_key_arn"
    deployment_parameters "$@"
)
callback='https://operations.example.test/auth/github/callback'
origins='https://app.example.test,https://other.example.test:8443'
registrations="$(cat <<'JSON'
["https://app.example.test/sign-in?next=ParameterKey=fixture,ParameterValue=one&label='demo'",
 "https://registered.example.test/return"]
JSON
)"
overrides="$(GITHUB_OAUTH_CALLBACK_URL="$callback" GITHUB_BROWSER_REDIRECT_URIS="$registrations" \
    OPERATIONS_BROWSER_ORIGINS="$origins" managed_deployment_parameters --enable-github-exchange)"
contains_line "$overrides" "GitHubOAuthCallbackUrl=$callback"
registrations_argument="$(cat <<'ARGUMENT'
ParameterKey=GitHubBrowserRedirectUris,ParameterValue='["https://app.example.test/sign-in?next=ParameterKey=fixture,ParameterValue=one&label=\'demo\'","https://registered.example.test/return"]'
ARGUMENT
)"
contains_line "$overrides" "$registrations_argument"
contains_line "$overrides" "OperationsBrowserOrigins=$origins"

# The CloudFormation parameter also excludes broad or path-based matches when
# the operator uses SAM without the deploy helper.
origin_pattern="$(sed -n "s/^    AllowedPattern: '\\(.*\\)'$/\\1/p" \
    <<<"$(template_section OperationsBrowserOrigins)")"
[[ "$origins" =~ $origin_pattern ]] || fail_test 'template rejects the configured origin list'
for invalid in '*' 'https://*' 'https://*.example.test' 'http://app.example.test' \
    'https://app.example.test/' 'https://app.example.test/path' \
    'https://app.example.test, https://other.example.test' 'https://app.example.test,'
do
    if [[ "$invalid" =~ $origin_pattern ]]; then fail_test 'template permits an invalid origin'; fi
    if output="$(OPERATIONS_BROWSER_ORIGINS="$invalid" \
        managed_deployment_parameters --enable-github-exchange 2>&1)"; then
        fail_test 'deploy helper permits an invalid origin'
    fi
    contains "$output" 'OPERATIONS_BROWSER_ORIGINS must be comma-separated HTTPS origins'
done
if output="$(GITHUB_BROWSER_REDIRECT_URIS="$registrations" \
    managed_deployment_parameters --enable-github-exchange 2>&1)"; then
    fail_test 'accepted app callback registration without the Operations callback'
fi
contains "$output" 'GITHUB_OAUTH_CALLBACK_URL must be'
if output="$(GITHUB_OAUTH_CALLBACK_URL="$callback" \
    managed_deployment_parameters --enable-github-exchange 2>&1)"; then
    fail_test 'accepted the Operations callback without app callback registration'
fi
contains "$output" 'GITHUB_BROWSER_REDIRECT_URIS must be'
overrides="$(GITHUB_OAUTH_CALLBACK_URL="$callback" GITHUB_BROWSER_REDIRECT_URIS="$registrations" \
    OPERATIONS_BROWSER_ORIGINS="$origins" managed_deployment_parameters --disable-github-exchange)"
contains_line "$overrides" 'EnableGitHubExchange=false'
absent "$overrides" 'GitHubClientId='
absent "$overrides" 'SecretArn='
absent "$overrides" 'GitHubOAuthCallbackUrl='
absent "$overrides" 'GitHubBrowserRedirectUris'
absent "$overrides" 'OperationsBrowserOrigins='
if output="$(GITHUB_CLIENT_ID=FixtureClient GITHUB_CLIENT_SECRET_ARN="$app_secret_arn" \
    PASETO_SIGNING_KEY_SECRET_ARN='fixture-invalid-reference' \
    deployment_parameters --enable-github-exchange 2>&1)"; then
    fail_test 'enabled GitHub exchange accepted an invalid signing-key reference'
fi
contains "$output" 'PASETO_SIGNING_KEY_SECRET_ARN must be a complete Secrets Manager ARN'
absent "$output" 'fixture-invalid-reference'
for option in --enable-github-exchange --disable-github-exchange; do
    if output="$(deployment_parameters --dev "$option" 2>&1)"; then
        fail_test "accepted $option during code-only sync"
    fi
    contains "$output" 'requires a full deployment'
done
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
