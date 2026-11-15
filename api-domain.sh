#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./api-domain.sh <setup|verify> <domain> [options]

  setup   Reconcile AWS resources, then print manual Cloudflare DNS instructions.
  verify  Inspect AWS and probe public HTTPS without creating Operations.

Options (after the domain):
  --profile PROFILE       Override AWS_PROFILE; otherwise use AWS CLI defaults.
  --region REGION         Override AWS_REGION; otherwise use AWS CLI defaults.
  --stack-name STACK      Default: STACK_NAME or aws-lambda-zig-demo.
  --stage STAGE           Existing stage; default: literal $default.
  --mapping-key KEY       Default: empty root mapping; e.g. staging or v1/test.
  --certificate-arn ARN   Select a setup certificate or assert the attached one.
  -h, --help              Show this help.

Requires Bash 3.2+, AWS CLI v2, jq and curl. No Cloudflare API calls.
Exit: 0 complete; 1 operational/verification failure; 2 invalid configuration;
      3 certificate validation or AWS resource readiness pending.
Setup success does not establish working HTTPS. Run verify after DNS propagation.
USAGE
}
config_error() { printf 'api-domain: %s\n' "$*" >&2; exit 2; }
failure() { printf 'api-domain: %s\n' "$*" >&2; exit 1; }
pending() { printf 'api-domain: %s Rerun setup when ready.\n' "$*" >&2; exit 3; }

[ "${BASH_VERSINFO[0]}" -gt 3 ] ||
    { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; } ||
    config_error 'Bash 3.2 or newer is required'
if [ "$#" -eq 1 ]; then
    case "$1" in -h|--help|help) usage; exit 0 ;; esac
fi
[ "$#" -ge 2 ] || config_error 'expected command and domain; use --help'
command_name="$1" domain="$2"
shift 2
case "$command_name" in setup|verify) ;; *) config_error 'command must be setup or verify' ;; esac
profile="${AWS_PROFILE:-}" region="${AWS_REGION:-}"
stack_name="${STACK_NAME:-aws-lambda-zig-demo}" stage='$default' mapping_key= certificate_arn=
while [ "$#" -gt 0 ]; do
    option="$1"
    case "$option" in
        -h|--help) usage; exit 0 ;;
        --profile|--region|--stack-name|--stage|--mapping-key|--certificate-arn)
            [ "$#" -ge 2 ] && [[ "$2" != --* ]] || config_error "missing value for $option"
            value="$2"; shift 2 ;;
        --profile=*|--region=*|--stack-name=*|--stage=*|--mapping-key=*|--certificate-arn=*)
            value="${option#*=}"; option="${option%%=*}"; shift ;;
        *) config_error "unexpected argument: $option; options follow the domain" ;;
    esac
    [ -n "$value" ] || [ "$option" = --mapping-key ] || config_error "$option must be nonempty"
    case "$option" in
        --profile) profile="$value" ;;
        --region) region="$value" ;;
        --stack-name) stack_name="$value" ;;
        --stage) stage="$value" ;;
        --mapping-key) mapping_key="$value" ;;
        --certificate-arn) certificate_arn="$value" ;;
    esac
done
domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
[[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$domain" == *.* ]] &&
    [ "${#domain}" -le 253 ] || config_error 'domain must be a DNS hostname, without scheme or path'
IFS=. read -r -a domain_labels <<<"$domain"
for label in "${domain_labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && [ "${#label}" -le 63 ] ||
        config_error 'invalid DNS label in domain'
done
[[ "$stack_name" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] && [ "${#stack_name}" -le 128 ] ||
    config_error 'invalid stack name'
[[ "$stage" = '$default' || "$stage" =~ ^[A-Za-z0-9_-]+$ ]] && [ "${#stage}" -le 128 ] ||
    config_error 'invalid stage name'
mapping_pattern="^[A-Za-z0-9\$_.+!*'()/-]*$"
[[ "$mapping_key" =~ $mapping_pattern && "$mapping_key" != /* &&
    "$mapping_key" != */ && "$mapping_key" != *//* ]] && [ "${#mapping_key}" -le 300 ] ||
    config_error 'invalid mapping key (no leading, trailing or repeated slash)'
[[ -z "$profile" || ( "$profile" != -* && "$profile" =~ [^[:space:]] ) ]] ||
    config_error 'invalid profile'
[[ -z "$region" || "$region" =~ ^[a-z0-9-]+$ ]] || config_error 'invalid Region'
[[ -z "$certificate_arn" || "$certificate_arn" =~ ^arn:[a-z0-9-]+:acm:[a-z0-9-]+:[^:]+:certificate/[A-Za-z0-9-]+$ ]] ||
    config_error 'invalid certificate ARN'
for dependency in aws jq curl; do
    command -v "$dependency" >/dev/null 2>&1 || config_error "missing required command: $dependency"
done
aws_version="$(aws --version 2>&1)" || config_error 'cannot read AWS CLI version'
[[ "$aws_version" = aws-cli/2.* ]] || config_error 'AWS CLI v2 is required'

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/api-domain.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
export AWS_PAGER= AWS_CLI_AUTO_PROMPT=off
aws_options=(--output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 30)
[ -z "$profile" ] || aws_options+=(--profile "$profile")
[ -z "$region" ] || aws_options+=(--region "$region")
aws_json() {
    local result
    if ! result="$(aws "$@" "${aws_options[@]}" 2>"$work_dir/aws-error")"; then
        cat "$work_dir/aws-error" >&2
        failure "AWS $1 $2 failed"
    fi
    printf '%s\n' "$result" | jq -e 'type == "object"' >/dev/null ||
        failure "invalid JSON from AWS $1 $2"
    printf '%s\n' "$result"
}

# CloudFormation resolves the CLI default context; its ARN pins subsequent reads/writes.
resource="$(aws_json cloudformation describe-stack-resource --stack-name "$stack_name" \
    --logical-resource-id OperationsApi)"
api_id="$(jq -er '.StackResourceDetail | select(.ResourceType == "AWS::ApiGatewayV2::Api") |
    .PhysicalResourceId | select(type == "string" and length > 0)' <<<"$resource")" ||
    config_error 'stack has no OperationsApi HTTP API resource'
stack_arn="$(jq -er '.StackResourceDetail.StackId' <<<"$resource")"
IFS=: read -r arn_marker partition service resolved_region account remainder <<<"$stack_arn"
[ "$arn_marker" = arn ] && [ "$service" = cloudformation ] &&
    [ -n "$resolved_region" ] && [ -n "$account" ] || failure 'invalid stack ARN'
[ -n "$region" ] || aws_options+=(--region "$resolved_region")
region="$resolved_region"
printf 'AWS context: account=%s region=%s profile=%s stack=%s\n' \
    "$account" "$region" "${profile:-AWS CLI default chain}" "$stack_name"
api="$(aws_json apigatewayv2 get-api --api-id "$api_id")"
[ "$(jq -r '.ProtocolType' <<<"$api")" = HTTP ] || config_error 'OperationsApi must be an HTTP API'
stage_json="$(aws_json apigatewayv2 get-stage --api-id "$api_id" --stage-name "$stage")"
[ "$(jq -r '.StageName' <<<"$stage_json")" = "$stage" ] || config_error 'requested stage does not exist'
if ! jq -e '.AutoDeploy == true or ((.DeploymentId // "") | length > 0)' <<<"$stage_json" >/dev/null; then
    config_error 'requested stage has no deployment'
fi

domain_json=
if domain_json="$(aws apigatewayv2 get-domain-name --domain-name "$domain" \
    "${aws_options[@]}" 2>"$work_dir/aws-error")"; then
    jq -e --arg domain "$domain" '
        .DomainName == $domain and
        ((.RoutingMode // "API_MAPPING_ONLY") == "API_MAPPING_ONLY") and
        ((.MutualTlsAuthentication.TruststoreUri // "") == "") and
        (.DomainNameConfigurations | length == 1) and
        (.DomainNameConfigurations[0] | .EndpointType == "REGIONAL" and .SecurityPolicy == "TLS_1_2")
    ' <<<"$domain_json" >/dev/null || config_error 'incompatible existing domain: require Regional TLS_1_2, API mappings only, no mutual TLS'
    attached_certificate="$(jq -er '.DomainNameConfigurations[0].CertificateArn' <<<"$domain_json")"
    [ -z "$certificate_arn" ] || [ "$certificate_arn" = "$attached_certificate" ] ||
        config_error '--certificate-arn differs from existing domain certificate'
    certificate_arn="$attached_certificate"
else
    if ! [[ "$(cat "$work_dir/aws-error")" = *NotFoundException* ]]; then
        cat "$work_dir/aws-error" >&2
        failure 'cannot inspect custom domain'
    fi
    domain_json=
    [ "$command_name" = setup ] || failure 'custom domain is missing (mapping configuration)'
fi

# Wildcards cover exactly one label, including when the domain is a certificate SAN.
certificate_covers='
    def covers($d): ascii_downcase as $n | $n == $d or
        (($n | startswith("*.")) and ($d | split(".") | .[1:] | join(".")) == $n[2:]);
'
read_certificate() {
    [[ "$1" = "arn:$partition:acm:$region:$account:certificate/"* ]] ||
        config_error 'certificate must belong to the stack account and Region'
    aws_json acm describe-certificate --certificate-arn "$1"
}
if [ -z "$certificate_arn" ]; then
    certificates="$(aws_json acm list-certificates --certificate-statuses ISSUED PENDING_VALIDATION \
        --includes keyTypes=RSA_1024,RSA_2048,RSA_3072,RSA_4096,EC_prime256v1,EC_secp384r1,EC_secp521r1)"
    jq -e '.CertificateSummaryList | type == "array"' <<<"$certificates" >/dev/null ||
        failure 'invalid ACM certificate list'
    candidates=()
    # Describe candidates too: summary SAN lists may be truncated by ACM.
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        candidate_json="$(read_certificate "$candidate")"
        if jq -e --arg domain "$domain" "$certificate_covers"'
            .Certificate | (.Type == "AMAZON_ISSUED" or .Type == "IMPORTED") and
            (.CertificateAuthorityArn == null) and
            any((.SubjectAlternativeNames // [.DomainName])[]; covers($domain)) and
            (.Status == "ISSUED" or (.Status == "PENDING_VALIDATION" and
                all(.DomainValidationOptions[]?; .ValidationMethod == "DNS")))
        ' <<<"$candidate_json" >/dev/null; then candidates+=("$candidate"); fi
    done < <(jq -r '.CertificateSummaryList[].CertificateArn' <<<"$certificates")
    case "${#candidates[@]}" in
        0)
            requested="$(aws_json acm request-certificate --domain-name "$domain" \
                --validation-method DNS --key-algorithm RSA_2048)"
            certificate_arn="$(jq -er '.CertificateArn' <<<"$requested")" ;;
        1) certificate_arn="${candidates[0]}" ;;
        *) config_error 'multiple matching ACM certificates; select --certificate-arn' ;;
    esac
fi
certificate="$(read_certificate "$certificate_arn")"
jq -e --arg domain "$domain" "$certificate_covers"'
    .Certificate | (.Type == "AMAZON_ISSUED" or .Type == "IMPORTED") and
    (.CertificateAuthorityArn == null) and
    any((.SubjectAlternativeNames // [.DomainName])[]; covers($domain))
' <<<"$certificate" >/dev/null || config_error 'certificate is not a public certificate covering this domain'
certificate_status="$(jq -r '.Certificate.Status' <<<"$certificate")"
printf 'Certificate: %s (%s)\n' "$certificate_arn" "$certificate_status"
print_validation_records() {
    printf '\nCloudflare permanent ACM validation records (keep for renewal):\n'
    jq -r '[.Certificate.DomainValidationOptions[]? | .ResourceRecord? |
        select(.Type == "CNAME" and .Name != null and .Value != null)] | unique_by(.Name)[] |
        "  CNAME  Name: \(.Name)  Target: \(.Value)  Proxy: DNS only  TTL: Auto"' <<<"$certificate"
    if ! jq -e 'any(.Certificate.DomainValidationOptions[]?; .ResourceRecord.Type == "CNAME")' \
        <<<"$certificate" >/dev/null; then
        if [ "$certificate_status" = PENDING_VALIDATION ]; then
            printf '  ACM has not returned validation CNAMEs yet; rerun shortly.\n'
        else
            printf '  No ACM DNS records available; imported/email-validated certificates need their own renewal process.\n'
        fi
    fi
}
case "$certificate_status" in
    ISSUED) ;;
    PENDING_VALIDATION)
        jq -e 'all(.Certificate.DomainValidationOptions[]?; .ValidationMethod == "DNS")' \
            <<<"$certificate" >/dev/null || config_error 'pending certificate requires DNS validation'
        print_validation_records
        pending 'Certificate validation pending; add the CNAME records in Cloudflare. If records are not yet available, rerun shortly.' ;;
    *) config_error "certificate cannot be used: $certificate_status" ;;
esac

if [ -z "$domain_json" ]; then
    configuration="$(jq -cn --arg arn "$certificate_arn" \
        '[{EndpointType:"REGIONAL",SecurityPolicy:"TLS_1_2",CertificateArn:$arn}]')"
    domain_json="$(aws_json apigatewayv2 create-domain-name --domain-name "$domain" \
        --domain-name-configurations "$configuration" --routing-mode API_MAPPING_ONLY)"
fi
domain_status="$(jq -r '.DomainNameConfigurations[0].DomainNameStatus' <<<"$domain_json")"
case "$domain_status" in
    AVAILABLE) ;;
    UPDATING|PENDING_CERTIFICATE_REIMPORT|PENDING_OWNERSHIP_VERIFICATION)
        pending "Custom domain is $domain_status." ;;
    *) failure "unexpected domain readiness: $domain_status" ;;
esac
target="$(jq -er '.DomainNameConfigurations[0].ApiGatewayDomainName | select(length > 0)' <<<"$domain_json")"
mappings="$(aws_json apigatewayv2 get-api-mappings --domain-name "$domain")"
selected="$(jq -c --arg key "$mapping_key" '[.Items[]? | select((.ApiMappingKey // "") == $key)]' <<<"$mappings")"
[ "$(jq length <<<"$selected")" -le 1 ] || config_error 'ambiguous selected API mapping'
mapping_id="$(jq -r '.[0].ApiMappingId // empty' <<<"$selected")"
mapping_matches=false
if jq -e --arg api "$api_id" --arg stage "$stage" \
    'length == 1 and .[0].ApiId == $api and .[0].Stage == $stage' <<<"$selected" >/dev/null; then
    mapping_matches=true
fi
base_url="https://$domain${mapping_key:+/$mapping_key}"
if [ "$command_name" = setup ]; then
    if [ -z "$mapping_id" ]; then
        mapping_options=(--domain-name "$domain" --api-id "$api_id" --stage "$stage")
        [ -z "$mapping_key" ] || mapping_options+=(--api-mapping-key "$mapping_key")
        aws_json apigatewayv2 create-api-mapping "${mapping_options[@]}" >/dev/null
    elif [ "$mapping_matches" = false ]; then
        aws_json apigatewayv2 update-api-mapping --domain-name "$domain" \
            --api-mapping-id "$mapping_id" --api-id "$api_id" --stage "$stage" >/dev/null
    fi
    print_validation_records
    printf '\nCloudflare traffic record:\n  CNAME  Name: %s  Target: %s  Proxy: DNS only  TTL: Auto\n' "$domain" "$target"
    printf 'Enter the full record names above; avoid appending the zone name twice.\n'
    printf '\nAWS setup complete. API URL: %s\nHTTPS has not been verified. After DNS propagation run:\n' "$base_url"
    printf '  ./api-domain.sh verify %q --stack-name %q --region %q --stage %q --mapping-key %q' \
        "$domain" "$stack_name" "$region" "$stage" "$mapping_key"
    [ -z "$profile" ] || printf ' --profile %q' "$profile"
    printf '\n'
    exit 0
fi

[ "$mapping_matches" = true ] || failure 'mapping is missing or points to a different API/stage'
probe_uuid=00000000-0000-4000-8000-000000000001
probe_path="${mapping_key:+$mapping_key/}operations"
# Multi-level mappings use raw longest-prefix matching, even within a path segment.
shadowed="$(jq -r --arg path "$probe_path" --arg uuid "$probe_uuid" --arg key "$mapping_key" '
    any(.Items[]?; (.ApiMappingKey // "") | contains("/")) as $multi |
    def matches($other): . == $other or startswith($other + "/") or
        ($multi and startswith($other));
    any(.Items[]?; (.ApiMappingKey // "") as $other |
        ($other | length) > ($key | length) and
        (($path | matches($other)) or (($path + "/" + $uuid) | matches($other))))
' <<<"$mappings")"
[ "$shadowed" = false ] || failure 'another API mapping shadows a verification probe path'
probe() {
    local method="$1" path="$2" expected="$3" status curl_status=0
    # Disable curlrc and proxies so probes use public DNS, normal trust and no credentials.
    status="$(curl --disable --silent --show-error --noproxy '*' --proto '=https' \
        --tlsv1.2 --connect-timeout 10 --max-time 30 --max-redirs 0 \
        --request "$method" --dump-header "$work_dir/headers" --output /dev/null \
        --write-out '%{http_code}' "$base_url$path" 2>"$work_dir/curl-error")" || curl_status=$?
    if [ "$curl_status" -ne 0 ]; then
        cat "$work_dir/curl-error" >&2
        case "$curl_status" in
            5|6) failure 'DNS resolution failed for HTTPS probe' ;;
            28) failure 'HTTPS probe timed out' ;;
            35|51|53|58|59|60|64|66|77|80|82|83|90|91) failure 'TLS validation/handshake failed' ;;
            *) failure "HTTPS connection failed (curl $curl_status)" ;;
        esac
    fi
    case "$status" in 3??) failure "redirect received for $method $path (HTTP $status); redirects are not followed" ;; esac
    [ "$status" = "$expected" ] || failure "unexpected response for $method $path: HTTP $status (expected $expected; check DNS and routing)"
    if [ "$expected" = 401 ]; then
        tr -d '\r' <"$work_dir/headers" | LC_ALL=C awk '
            tolower($0) ~ /^www-authenticate:[ \t]*bearer([ \t,]|$)/ { found=1 }
            END { exit !found }
        ' || failure "missing WWW-Authenticate: Bearer challenge for $method $path"
    fi
    printf 'Verified %s %s -> %s\n' "$method" "$base_url$path" "$status"
}
probe POST /operations 401
probe GET "/operations/$probe_uuid" 401
probe GET /operations 404
printf '\nSUCCESS: API domain verification passed for %s.\n' "$base_url"
printf 'AWS configuration, public HTTPS and unauthenticated routing verified. No Operations submitted.\n'
