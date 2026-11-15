#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/api-domain-test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/state"
while IFS= read -r key; do unset "$key"; done < <(compgen -e | sed -n '/^AWS_/p')
unset STACK_NAME
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export PATH="$TEST_DIR/bin:$PATH" STATE="$TEST_DIR/state"
export AWS_CALLS="$TEST_DIR/aws-calls" HTTP_CALLS="$TEST_DIR/http-calls"
export CERT_ARN='arn:aws:acm:eu-west-1:example-account:certificate/fixture'
export READ_ONLY=false CURL_EXIT=0 CURL_RESPONSE=normal
output="$TEST_DIR/output"
fail_test() { printf 'FAIL: %s\n' "$*" >&2; cat "$output" >&2; exit 1; }
contains() { case "$(cat "$output")" in *"$1"*) ;; *) fail_test "missing output: $1" ;; esac; }
run_expect() {
    local expected="$1" actual=0; shift
    : >"$AWS_CALLS"; : >"$HTTP_CALLS"
    bash "$REPOSITORY_ROOT/api-domain.sh" "$@" >"$output" 2>&1 || actual=$?
    [ "$actual" -eq "$expected" ] || fail_test "exit $actual, expected $expected: $*"
}
no_mutations() {
    jq -se 'all(.[]; .[1] | test("^(get-|describe-|list-)") or . == null)' \
        "$AWS_CALLS" >/dev/null || fail_test 'unexpected AWS mutation'
}
called() { jq -se --arg op "$1" 'any(.[]; .[1] == $op)' "$AWS_CALLS" >/dev/null; }
edit_json() {
    local file="$1" filter="$2"; shift 2
    jq "$@" "$filter" "$STATE/$file" >"$STATE/edit"
    mv "$STATE/edit" "$STATE/$file"
}
reset_state() {
    READ_ONLY=false CURL_EXIT=0 CURL_RESPONSE=normal
    unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION STACK_NAME AWS_VERSION DOMAIN_ERROR STAGE_ERROR
    export EXPECT_BASE=https://api.example.com
    printf '%s\n' '{"StackResourceDetail":{"PhysicalResourceId":"api-current","ResourceType":"AWS::ApiGatewayV2::Api","StackId":"arn:aws:cloudformation:eu-west-1:example-account:stack/fixture/id"}}' >"$STATE/resource"
    printf '%s\n' '{"ApiId":"api-current","ProtocolType":"HTTP"}' >"$STATE/api"
    printf '%s\n' '{"StageName":"$default","AutoDeploy":true}' >"$STATE/stage"
    jq -n --arg arn "$CERT_ARN" '{DomainName:"api.example.com",RoutingMode:"API_MAPPING_ONLY",
        DomainNameConfigurations:[{EndpointType:"REGIONAL",SecurityPolicy:"TLS_1_2",
            CertificateArn:$arn,DomainNameStatus:"AVAILABLE",ApiGatewayDomainName:"regional-api.invalid"}]}' >"$STATE/domain"
    jq -n --arg arn "$CERT_ARN" '{Certificate:{CertificateArn:$arn,DomainName:"api.example.com",
        SubjectAlternativeNames:["api.example.com"],Type:"AMAZON_ISSUED",Status:"ISSUED",
        DomainValidationOptions:[{DomainName:"api.example.com",ValidationMethod:"DNS",
            ResourceRecord:{Type:"CNAME",Name:"_fixture.api.example.com.",Value:"_target.acm-validations.aws."}}]}}' >"$STATE/certificate"
    jq -n --arg arn "$CERT_ARN" '{CertificateSummaryList:[{CertificateArn:$arn,DomainName:"api.example.com"}]}' >"$STATE/certificates"
    printf '%s\n' '{"Items":[{"ApiMappingId":"selected","ApiMappingKey":"","ApiId":"api-current","Stage":"$default"},{"ApiMappingId":"other","ApiMappingKey":"unrelated","ApiId":"other-api","Stage":"other"}]}' >"$STATE/mappings"
}

cat >"$TEST_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = --version ]; then printf '%s\n' "${AWS_VERSION:-aws-cli/2.40.0 fixture}"; exit; fi
jq -cn --args '$ARGS.positional' -- "$@" >>"$AWS_CALLS"
service="$1" operation="$2"; shift 2
api= stage= key= mapping_id= configuration= domain=
while [ "$#" -gt 0 ]; do
    option="$1" value="${2:-}"
    case "$option" in
        --api-id) api="$value" ;;
        --stage|--stage-name) stage="$value" ;;
        --api-mapping-key) key="$value" ;;
        --api-mapping-id) mapping_id="$value" ;;
        --domain-name-configurations) configuration="$value" ;;
        --domain-name) domain="$value" ;;
    esac
    shift
done
case "$operation" in get-*|describe-*|list-*) ;;
    *) [ "$READ_ONLY" = false ] || { printf 'FORBIDDEN MUTATION\n' >&2; exit 99; } ;;
esac
case "$service $operation" in
    'cloudformation describe-stack-resource') cat "$STATE/resource" ;;
    'apigatewayv2 get-api') cat "$STATE/api" ;;
    'apigatewayv2 get-stage')
        [ "${STAGE_ERROR:-false}" = false ] || exit 98
        cat "$STATE/stage" ;;
    'apigatewayv2 get-domain-name')
        [ "${DOMAIN_ERROR:-false}" = false ] || { printf 'AccessDeniedException\n' >&2; exit 97; }
        [ -f "$STATE/domain" ] || { printf 'NotFoundException\n' >&2; exit 254; }
        cat "$STATE/domain" ;;
    'acm list-certificates') cat "$STATE/certificates" ;;
    'acm describe-certificate') cat "$STATE/certificate" ;;
    'acm request-certificate')
        jq '.Certificate.Status="PENDING_VALIDATION"' "$STATE/certificate" >"$STATE/edit"
        mv "$STATE/edit" "$STATE/certificate"
        jq -n --arg arn "$CERT_ARN" '{CertificateArn:$arn}'
        jq -n --arg arn "$CERT_ARN" '{CertificateSummaryList:[{CertificateArn:$arn}]}' >"$STATE/certificates" ;;
    'apigatewayv2 create-domain-name')
        jq -e 'length == 1 and .[0].EndpointType == "REGIONAL" and .[0].SecurityPolicy == "TLS_1_2"' \
            <<<"$configuration" >/dev/null || exit 96
        jq -n --arg domain "$domain" --argjson config "$configuration" \
            '{DomainName:$domain,RoutingMode:"API_MAPPING_ONLY",DomainNameConfigurations:
                [$config[0] + {DomainNameStatus:"AVAILABLE",ApiGatewayDomainName:"regional-api.invalid"}]}' >"$STATE/domain"
        cat "$STATE/domain" ;;
    'apigatewayv2 get-api-mappings') cat "$STATE/mappings" ;;
    'apigatewayv2 create-api-mapping')
        jq --arg key "$key" --arg api "$api" --arg stage "$stage" \
            '.Items += [{ApiMappingId:("created-" + $key),ApiMappingKey:$key,ApiId:$api,Stage:$stage}]' \
            "$STATE/mappings" >"$STATE/edit"
        mv "$STATE/edit" "$STATE/mappings"
        printf '{}\n' ;;
    'apigatewayv2 update-api-mapping')
        jq --arg id "$mapping_id" --arg api "$api" --arg stage "$stage" \
            '(.Items[] | select(.ApiMappingId == $id)) |= (.ApiId=$api | .Stage=$stage)' \
            "$STATE/mappings" >"$STATE/edit"
        mv "$STATE/edit" "$STATE/mappings"
        printf '{}\n' ;;
    *) printf 'unexpected AWS command: %s %s\n' "$service" "$operation" >&2; exit 95 ;;
esac
MOCK
cat >"$TEST_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >>"$HTTP_CALLS"
[ "$1" = --disable ] || exit 94
headers= method= url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dump-header) headers="$2"; shift ;;
        --request) method="$2"; shift ;;
        https://*) url="$1" ;;
        --insecure|-k|--location|-L|--data*|-d|--header|-H|--tls-max|--resolve|--connect-to)
            printf 'unsafe probe option\n' >&2; exit 93 ;;
    esac
    shift
done
[ "$CURL_EXIT" -eq 0 ] || exit "$CURL_EXIT"
status=401
case "$method $url" in
    "POST $EXPECT_BASE/operations"|"GET $EXPECT_BASE/operations/00000000-0000-4000-8000-000000000001") ;;
    "GET $EXPECT_BASE/operations") status=404 ;;
    *) printf 'unexpected probe destination\n' >&2; exit 92 ;;
esac
case "$CURL_RESPONSE" in
    redirect) status=302 ;;
    unexpected) status=200 ;;
    throttled) status=429 ;;
    query_failure) [ "$method" != GET ] || status=500 ;;
esac
printf 'HTTP/2 %s\r\n' "$status" >"$headers"
case "$CURL_RESPONSE" in
    missing_challenge) ;;
    wrong_challenge) printf 'WWW-Authenticate: Basic\r\n' >>"$headers" ;;
    *) printf 'wWw-AuThEnTiCaTe: Bearer\r\n' >>"$headers" ;;
esac
printf '%s' "$status"
MOCK
chmod +x "$TEST_DIR/bin/aws" "$TEST_DIR/bin/curl"

reset_state
for command in setup verify; do
    run_expect 0 "$command" api.example.com --help
    [ ! -s "$AWS_CALLS" ] || fail_test 'help contacted AWS'
done
run_expect 0 --help
for invalid in '' setup destroy '--domain api.example.com'; do
    # These cases intentionally split command words; hostname/options below stay quoted.
    run_expect 2 $invalid
    [ ! -s "$AWS_CALLS" ] || fail_test 'invalid command contacted AWS'
done
for arguments in extra --domain --unknown; do
    run_expect 2 setup api.example.com "$arguments"
    [ ! -s "$AWS_CALLS" ] || fail_test 'invalid positional/option contacted AWS'
done
for domain in https://api.example.com api.example.com/path '*.example.com' a..example.com '-api.example.com' localhost; do
    run_expect 2 setup "$domain"
    [ ! -s "$AWS_CALLS" ] || fail_test 'invalid domain contacted AWS'
done
for option in --profile --region --stack-name --stage --certificate-arn --mapping-key; do
    run_expect 2 setup api.example.com "$option"
    [ ! -s "$AWS_CALLS" ] || fail_test 'missing value contacted AWS'
done
for key in /staging staging/ a//b 'bad key' 'a?b'; do
    run_expect 2 setup api.example.com --mapping-key "$key"
    [ ! -s "$AWS_CALLS" ] || fail_test 'invalid mapping contacted AWS'
done
run_expect 0 setup api.example.com
no_mutations
contains '_fixture.api.example.com.'
contains '_target.acm-validations.aws.'
contains 'Name: api.example.com  Target: regional-api.invalid'
contains 'Proxy: DNS only  TTL: Auto'
contains 'HTTPS has not been verified'
jq -se '.[0] | index("--profile") == null and index("--region") == null' "$AWS_CALLS" >/dev/null ||
    fail_test 'hardcoded AWS context'
jq -se '.[1:] | all(.[]; index("--region") as $i | .[$i+1] == "eu-west-1")' "$AWS_CALLS" >/dev/null ||
    fail_test 'did not resolve the CLI default Region'
export AWS_PROFILE=environment-profile AWS_REGION=eu-west-1 STACK_NAME=environment-stack
run_expect 0 setup api.example.com
jq -se 'all(.[]; index("--profile") as $p | .[$p+1] == "environment-profile") and
    (.[0] | index("--stack-name") as $s | .[$s+1] == "environment-stack")' "$AWS_CALLS" >/dev/null || fail_test 'environment defaults'
run_expect 0 setup api.example.com --profile explicit-profile --region eu-west-1 --stack-name explicit-stack
jq -se 'all(.[]; index("--profile") as $p | .[$p+1] == "explicit-profile") and
    (.[0] | index("--stack-name") as $s | .[$s+1] == "explicit-stack")' "$AWS_CALLS" >/dev/null || fail_test 'explicit overrides'
reset_state
export AWS_REGION=us-west-2
run_expect 0 setup api.example.com --region eu-west-1
jq -se 'all(.[]; index("--region") as $r | .[$r+1] == "eu-west-1")' "$AWS_CALLS" >/dev/null || fail_test 'Region override'

# Fresh setup reuses a matching certificate and preserves unrelated mappings.
reset_state
rm "$STATE/domain"
edit_json mappings '.Items |= map(select(.ApiMappingId != "selected"))'
run_expect 0 setup api.example.com
called create-domain-name && called create-api-mapping || fail_test 'resources not created'
if called request-certificate; then fail_test 'ignored reusable certificate'; fi
other_mapping="$(jq -c '.Items[] | select(.ApiMappingId == "other")' "$STATE/mappings")"
run_expect 0 setup api.example.com
no_mutations
run_expect 0 setup api.example.com --stage staging --mapping-key staging --help
edit_json stage '.StageName="staging"'
run_expect 0 setup api.example.com --stage staging --mapping-key staging
contains 'API URL: https://api.example.com/staging'
called create-api-mapping || fail_test 'prefix mapping missing'
edit_json resource '.StackResourceDetail.PhysicalResourceId="api-replacement"'
run_expect 0 setup api.example.com --stage staging --mapping-key staging
called update-api-mapping || fail_test 'did not switch API destination'
jq -e '.Items[] | select(.ApiMappingKey == "") | .ApiId == "api-current"' "$STATE/mappings" >/dev/null || fail_test 'root mapping changed'
[ "$(jq -c '.Items[] | select(.ApiMappingId == "other")' "$STATE/mappings")" = "$other_mapping" ] || fail_test 'other mapping changed'
edit_json stage '.StageName="production"'
run_expect 0 setup api.example.com --stage production --mapping-key staging
called update-api-mapping || fail_test 'did not switch stage'
run_expect 0 setup api.example.com --stage production --mapping-key staging
no_mutations

# A requested pending certificate is reused across invocations and then resumes.
reset_state
rm "$STATE/domain"
printf '{"CertificateSummaryList":[]}\n' >"$STATE/certificates"
run_expect 3 setup api.example.com
called request-certificate || fail_test 'certificate not requested'
contains '_fixture.api.example.com.'
if called create-domain-name; then fail_test 'domain created before validation'; fi
run_expect 3 setup api.example.com
no_mutations
edit_json certificate '.Certificate.Status="ISSUED"'
run_expect 0 setup api.example.com
called create-domain-name || fail_test 'setup did not resume'
reset_state
rm "$STATE/domain"
edit_json certificates '.CertificateSummaryList += .CertificateSummaryList'
run_expect 2 setup api.example.com
contains 'multiple matching'
no_mutations
run_expect 0 setup api.example.com --certificate-arn "$CERT_ARN"
if called list-certificates; then fail_test 'explicit certificate ignored'; fi

# Incompatible resources fail before mutation; SAN and wildcard certificates work.
for filter in '.DomainNameConfigurations[0].EndpointType="EDGE"' \
    '.DomainNameConfigurations[0].SecurityPolicy="TLS_1_0"' \
    '.RoutingMode="ROUTING_RULE_THEN_API_MAPPING"' \
    '.MutualTlsAuthentication={TruststoreUri:"s3://<bucket-name>/trust"}'; do
    reset_state; edit_json domain "$filter"
    run_expect 2 setup api.example.com
    no_mutations
done
reset_state
run_expect 2 setup api.example.com --certificate-arn "${CERT_ARN}different"
no_mutations
reset_state
edit_json certificate '.Certificate.SubjectAlternativeNames=["*.example.com"]'
run_expect 0 setup api.example.com
edit_json certificate '.Certificate.SubjectAlternativeNames=["*.other.example.com"]'
run_expect 2 setup api.example.com
edit_json certificate '.Certificate.SubjectAlternativeNames=["api.example.com"] | .Certificate.Status="EXPIRED"'
run_expect 2 setup api.example.com
reset_state
edit_json domain '.DomainNameConfigurations[0].CertificateArn="arn:aws:acm:us-west-2:example-account:certificate/fixture"'
run_expect 2 setup api.example.com
reset_state
edit_json api '.ProtocolType="WEBSOCKET"'
run_expect 2 setup api.example.com
no_mutations
reset_state
edit_json stage '.AutoDeploy=false'
run_expect 2 setup api.example.com
no_mutations
reset_state
export STAGE_ERROR=true
run_expect 1 setup api.example.com
no_mutations
reset_state
export DOMAIN_ERROR=true
run_expect 1 setup api.example.com
no_mutations
reset_state
edit_json domain '.DomainNameConfigurations[0].DomainNameStatus="UPDATING"'
run_expect 3 setup api.example.com
no_mutations
reset_state
export AWS_VERSION=aws-cli/1.0
run_expect 2 setup api.example.com
[ ! -s "$AWS_CALLS" ] || fail_test 'AWS v1 used'

# Verification's mock rejects every non-read command regardless of test assertions.
reset_state; READ_ONLY=true
edit_json mappings '.Items += [{ApiMappingId:"short-prefix",ApiMappingKey:"oper",ApiId:"other-api",Stage:"other"}]'
run_expect 0 verify api.example.com
# Single-level mappings match complete segments, so "oper" does not shadow operations.
reset_state; READ_ONLY=true
run_expect 0 verify api.example.com --certificate-arn "$CERT_ARN"
contains 'SUCCESS: API domain verification passed for https://api.example.com.'
no_mutations
jq -se 'length == 3 and all(.[]; index("--tlsv1.2") != null and index("--tls-max") == null and
    index("--max-time") != null and index("--connect-timeout") != null and
    index("--noproxy") != null and index("--location") == null)' "$HTTP_CALLS" >/dev/null || fail_test 'probe transport policy'
edit_json mappings '(.Items[] | select(.ApiMappingId == "selected")) |= (.ApiMappingKey="staging" | .Stage="staging")'
edit_json stage '.StageName="staging"'
export EXPECT_BASE=https://api.example.com/staging
run_expect 0 verify api.example.com --stage staging --mapping-key staging
for filter in '.Items += [{ApiMappingKey:"staging/operations"}]' \
    '.Items += [{ApiMappingKey:"staging/operations/00000000-0000-4000-8000-000000000001"}]' \
    '.Items += [{ApiMappingKey:"staging/oper"}]'; do
    cp "$STATE/mappings" "$STATE/saved"
    edit_json mappings "$filter"
    run_expect 1 verify api.example.com --stage staging --mapping-key staging
    contains 'shadows'
    [ ! -s "$HTTP_CALLS" ] || fail_test 'probed shadowed mapping'
    mv "$STATE/saved" "$STATE/mappings"
done
reset_state; READ_ONLY=true
for code in 6 28 35 60 7; do
    CURL_EXIT="$code"
    run_expect 1 verify api.example.com
    case "$code" in 6) contains DNS ;; 28) contains 'timed out' ;; 35|60) contains TLS ;; 7) contains connection ;; esac
    no_mutations
done
CURL_EXIT=0
for response in redirect unexpected throttled query_failure missing_challenge wrong_challenge; do
    CURL_RESPONSE="$response"
    run_expect 1 verify api.example.com
    no_mutations
    case "$response" in redirect) contains redirect ;; *challenge) contains 'WWW-Authenticate' ;; *) contains 'unexpected response' ;; esac
done
reset_state; READ_ONLY=true
edit_json mappings '(.Items[] | select(.ApiMappingId == "selected")).ApiId="stale-api"'
run_expect 1 verify api.example.com
contains 'different API/stage'
no_mutations
reset_state; READ_ONLY=true
edit_json certificate '.Certificate.Status="PENDING_VALIDATION"'
run_expect 3 verify api.example.com
no_mutations
reset_state; READ_ONLY=true
rm "$STATE/domain"
run_expect 1 verify api.example.com
no_mutations
reset_state
edit_json stage '.AutoDeploy=false | .DeploymentId="deployment-existing"'
run_expect 0 setup api.example.com --mapping-key= --stage='$default'
reset_state
edit_json certificate '.Certificate.DomainValidationOptions=[] | .Certificate.Status="PENDING_VALIDATION"'
run_expect 3 setup api.example.com
contains 'records are not yet available'
no_mutations
printf 'API domain helper regression tests passed.\n'
