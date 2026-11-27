#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'deploy-demo-web: %s\n' "$1" >&2
    exit 1
}

usage() {
    printf '%s\n' 'Usage: ./deploy-demo-web.sh' \
        'Publishes demo-web to S3 and refreshes the CloudFront cache.' \
        'Set DEMO_WEB_STACK_NAME to override electrit-demo-web.' \
        'Select the AWS CLI profile as usual. The hosting stack is in us-east-1.'
}

if [[ $# -eq 1 && ( $1 == -h || $1 == --help ) ]]; then
    usage
    exit 0
fi
if [[ $# -ne 0 ]]; then
    usage >&2
    exit 2
fi

for utility in aws jq file; do
    command -v "$utility" >/dev/null 2>&1 || fail "Required command '$utility' is missing."
done

stack_name="${DEMO_WEB_STACK_NAME:-electrit-demo-web}"
export AWS_PAGER= AWS_CLI_AUTO_PROMPT=off
CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/demo-web"
for asset in index.html style.css sign-in.js; do
    [[ -f "$asset" && ! -L "$asset" ]] || fail "Missing regular asset file: $asset"
done
[[ -d assets && ! -L assets ]] || fail 'Missing demo-web/assets directory.'

asset_list="$(mktemp "${TMPDIR:-/tmp}/demo-web-assets.XXXXXX")"
trap 'rm -f -- "$asset_list"' EXIT
# Match .assetsignore. Publish the entry point after its dependencies.
{
    find assets -type f -print0
    printf '%s\0' style.css sign-in.js index.html
} >"$asset_list"

outputs="$(aws cloudformation describe-stacks --region us-east-1 --stack-name "$stack_name" \
    --query 'Stacks[0].Outputs' --output json)" || fail "Could not read hosting stack '$stack_name'."
bucket_name="$(jq -er '.[] | select(.OutputKey == "AssetsBucketName") | .OutputValue | strings | select(length > 0)' <<<"$outputs")" ||
    fail "Hosting stack '$stack_name' has no AssetsBucketName output."
distribution_id="$(jq -er '.[] | select(.OutputKey == "DistributionId") | .OutputValue | strings | select(length > 0)' <<<"$outputs")" ||
    fail "Hosting stack '$stack_name' has no DistributionId output."

# Browsers revalidate on reuse. CloudFront can cache for one hour or until invalidated.
cache_control='public, max-age=0, s-maxage=3600, must-revalidate'
while IFS= read -r -d '' asset; do
    [[ -f "$asset" && ! -L "$asset" ]] || fail "Missing regular asset file: $asset"
    case "${asset##*/}" in
        *.html) content_type=text/html ;;
        *.css) content_type=text/css ;;
        *.js) content_type=text/javascript ;;
        *.svg) content_type=image/svg+xml ;;
        *.woff2) content_type=font/woff2 ;;
        *.txt) content_type=text/plain ;;
        *) content_type="$(file --brief --mime-type "$asset")" ;;
    esac
    aws s3api put-object --region us-east-1 --bucket "$bucket_name" --key "$asset" \
        --body "$asset" --content-type "$content_type" --cache-control "$cache_control" >/dev/null ||
        fail "Could not publish '$asset'."
done <"$asset_list"

invalidation_id="$(aws cloudfront create-invalidation --region us-east-1 \
    --distribution-id "$distribution_id" --paths '/*' --query 'Invalidation.Id' --output text)" ||
    fail 'Could not create a CloudFront invalidation.'
[[ -n "$invalidation_id" && "$invalidation_id" != None ]] || fail 'CloudFront returned no invalidation ID.'
aws cloudfront wait invalidation-completed --region us-east-1 \
    --distribution-id "$distribution_id" --id "$invalidation_id" ||
    fail "CloudFront invalidation '$invalidation_id' did not complete."
printf 'Published demo-web to %s and refreshed CloudFront (%s).\n' "$bucket_name" "$invalidation_id"
