#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/deploy-demo-web-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
project="$test_dir/checkout with spaces"
mkdir -p "$test_dir/bin" "$test_dir/s3" "$project/demo-web/assets/nested"
cp "$repo_root/deploy-demo-web.sh" "$project/"
printf 'first HTML' >"$project/demo-web/index.html"
printf 'first CSS' >"$project/demo-web/style.css"
printf 'first JavaScript' >"$project/demo-web/sign-in.js"
printf '<svg/>' >"$project/demo-web/assets/nested/test mark.svg"
printf 'font data' >"$project/demo-web/assets/font.woff2"
printf 'Font license' >"$project/demo-web/assets/OFL.txt"
printf 'Unmapped extension' >"$project/demo-web/assets/extra.data"
printf 'Internal notes' >"$project/demo-web/README.md"
ln -s ../README.md "$project/demo-web/assets/notes.txt"
ln -s .. "$project/demo-web/assets/linked-dir"

cat >"$test_dir/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "$AWS_PAGER" && "$AWS_CLI_AUTO_PROMPT" == off ]]
case "$1 $2" in
    'cloudformation describe-stacks')
        printf 'describe\n' >>"$AWS_LOG"
        [[ $# -eq 10 && "$3 $4 $5 $6 $7 $8 $9 ${10}" == \
            "--region us-east-1 --stack-name ${DEMO_WEB_STACK_NAME:-electrit-demo-web} --query Stacks[0].Outputs --output json" ]]
        [[ "$SCENARIO" != missing-stack ]] || exit 1
        if [[ "$SCENARIO" == missing-output ]]; then
            printf '[{"OutputKey":"AssetsBucketName","OutputValue":"fixture-bucket"}]\n'
        else
            printf '[{"OutputKey":"AssetsBucketName","OutputValue":"fixture-bucket"},{"OutputKey":"DistributionId","OutputValue":"EFIXTURE"}]\n'
        fi
        ;;
    's3api put-object')
        [[ $# -eq 14 && "$3 $4 $5 $6 $7 $9 ${11} ${13}" == \
            '--region us-east-1 --bucket fixture-bucket --key --body --content-type --cache-control' ]]
        key="$8"
        [[ "${10}" == "$key" && "${14}" == 'public, max-age=0, s-maxage=3600, must-revalidate' ]]
        case "$key" in
            index.html) mime=text/html ;;
            style.css) mime=text/css ;;
            sign-in.js) mime=text/javascript ;;
            'assets/nested/test mark.svg') mime=image/svg+xml ;;
            assets/font.woff2) mime=font/woff2 ;;
            assets/OFL.txt|assets/extra.data) mime=text/plain ;;
            *) exit 90 ;;
        esac
        [[ "${12}" == "$mime" ]]
        printf 'put %s\n' "$key" >>"$AWS_LOG"
        [[ "$SCENARIO $key" != 'upload-error style.css' ]] || exit 1
        mkdir -p "$MOCK_S3/$(dirname "$key")"
        cp "$key" "$MOCK_S3/$key"
        ;;
    'cloudfront create-invalidation')
        [[ $# -eq 12 && "$*" == \
            'cloudfront create-invalidation --region us-east-1 --distribution-id EFIXTURE --paths /* --query Invalidation.Id --output text' ]]
        printf 'invalidate\n' >>"$AWS_LOG"
        [[ "$SCENARIO" != invalidation-error ]] || exit 1
        if [[ "$SCENARIO" == missing-invalidation ]]; then
            printf 'None\n'
        else
            printf 'IFIXTURE\n'
        fi
        ;;
    'cloudfront wait')
        [[ $# -eq 9 && "$*" == \
            'cloudfront wait invalidation-completed --region us-east-1 --distribution-id EFIXTURE --id IFIXTURE' ]]
        printf 'wait\n' >>"$AWS_LOG"
        [[ "$SCENARIO" != wait-error ]]
        ;;
    *) exit 91 ;;
esac
MOCK
chmod +x "$test_dir/bin/aws"
export PATH="$test_dir/bin:$PATH" AWS_LOG="$test_dir/calls" MOCK_S3="$test_dir/s3"
unset DEMO_WEB_STACK_NAME
export SCENARIO=publish
cd "$test_dir"

run_deploy() {
    : >"$AWS_LOG"
    "$project/deploy-demo-web.sh" "$@" >actual 2>&1
}

assert_call_order() {
    printf '%s\n' "$@" | diff -u - "$AWS_LOG"
}

assert_publish() {
    [[ "$(head -n 1 "$AWS_LOG")" == describe ]]
    diff -u - <(sed -n '2,5p' "$AWS_LOG" | LC_ALL=C sort) <<'EXPECTED'
put assets/OFL.txt
put assets/extra.data
put assets/font.woff2
put assets/nested/test mark.svg
EXPECTED
    printf '%s\n' 'put style.css' 'put sign-in.js' 'put index.html' invalidate wait |
        diff -u - <(tail -n +6 "$AWS_LOG")
    for asset in index.html style.css sign-in.js; do
        cmp "$MOCK_S3/$asset" "$project/demo-web/$asset"
    done
    [[ "$(<actual)" == 'Published demo-web to fixture-bucket and refreshed CloudFront (IFIXTURE).' ]]
}

run_deploy --help
[[ ! -s "$AWS_LOG" && "$(<actual)" == *DEMO_WEB_STACK_NAME* ]]
if run_deploy --unknown; then exit 1; else [[ $? -eq 2 ]]; fi
[[ ! -s "$AWS_LOG" ]]

run_deploy
assert_publish

# Overwrite the same object keys, even when the replacements are the same size.
printf 'other HTML' >"$project/demo-web/index.html"
printf 'other CSS' >"$project/demo-web/style.css"
printf 'other JavaScript' >"$project/demo-web/sign-in.js"
DEMO_WEB_STACK_NAME=custom-demo-web run_deploy
assert_publish

mv "$project/demo-web/index.html" "$project/demo-web/index.html.bak"
ln -s index.html.bak "$project/demo-web/index.html"
if run_deploy; then exit 1; fi
[[ ! -s "$AWS_LOG" && "$(<actual)" == *'Missing regular asset file: index.html'* ]]
mv -f "$project/demo-web/index.html.bak" "$project/demo-web/index.html"

if SCENARIO=missing-stack run_deploy; then exit 1; fi
assert_call_order describe
[[ "$(<actual)" == *'Could not read hosting stack'* ]]

if SCENARIO=missing-output run_deploy; then exit 1; fi
assert_call_order describe
[[ "$(<actual)" == *'no DistributionId output'* ]]

if SCENARIO=upload-error run_deploy; then exit 1; fi
[[ "$(tail -n 1 "$AWS_LOG")" == 'put style.css' && "$(<actual)" == *"Could not publish 'style.css'"* ]]

if SCENARIO=invalidation-error run_deploy; then exit 1; fi
[[ "$(tail -n 1 "$AWS_LOG")" == invalidate && "$(<actual)" == *'Could not create a CloudFront invalidation'* ]]

if SCENARIO=missing-invalidation run_deploy; then exit 1; fi
[[ "$(tail -n 1 "$AWS_LOG")" == invalidate && "$(<actual)" == *'returned no invalidation ID'* ]]

if SCENARIO=wait-error run_deploy; then exit 1; fi
[[ "$(tail -n 1 "$AWS_LOG")" == wait && "$(<actual)" == *"invalidation 'IFIXTURE' did not complete"* ]]

# The browser gets the root document at the callback URL, while the edge and
# origin use the path without query fields. No request logs or samples are enabled.
jq -e '
    .Resources as $resources
    | $resources.Distribution.Properties.DistributionConfig as $distribution
    | $distribution.DefaultCacheBehavior as $behavior
    | $resources.AssetsBucket.Properties as $bucket
    | $resources.AssetsBucketPolicy.Properties.PolicyDocument.Statement as $grants
    | $resources.FreePricingPlan.Properties as $plan
    | "arn:${AWS::Partition}:cloudfront::${AWS::AccountId}:distribution/${Distribution}" as $distribution_arn
    | $distribution.Aliases == ["demo.electrit.com"]
      and $distribution.DefaultRootObject == "index.html"
      and $distribution.ViewerCertificate.AcmCertificateArn == {Ref: "CertificateArn"}
      and $behavior.ViewerProtocolPolicy == "redirect-to-https"
      and $behavior.CachePolicyId == {Ref: "AssetsCachePolicy"}
      and ($resources.AssetsCachePolicy.Properties.CachePolicyConfig
          | .MinTTL == 0 and .MaxTTL == 3600
            and .ParametersInCacheKeyAndForwardedToOrigin.QueryStringsConfig.QueryStringBehavior == "none")
      and ($behavior | has("OriginRequestPolicyId") or has("ForwardedValues")
          or has("RealtimeLogConfigArn") or has("FunctionAssociations")
          or has("LambdaFunctionAssociations") | not)
      and ($distribution | has("Logging") or has("CacheBehaviors") or has("CustomErrorResponses") | not)
      and ($resources | all(.[]; .Type | startswith("AWS::Logs:") or . == "AWS::WAFv2::LoggingConfiguration" | not))
      and $resources.DemoWebAcl.Properties.VisibilityConfig.SampledRequestsEnabled == false
      and (.Parameters.EnableFreePricingPlan
          | .Type == "String" and .AllowedValues == ["false", "true"] and (has("Default") | not))
      and .Conditions.SubscribeToFreePlan == {"Fn::Equals": [{Ref: "EnableFreePricingPlan"}, "true"]}
      and $resources.FreePricingPlan.Condition == "SubscribeToFreePlan"
      and .Outputs.PricingPlanArn.Condition == "SubscribeToFreePlan"
      and ($resources.Distribution | has("Condition") | not)
      and $plan.PlanFamily == "CloudFront" and $plan.PlanTier == "FREE" and $plan.UsageLevel == "DEFAULT"
      and $plan.ResourceArns == [{"Fn::Sub": $distribution_arn}, {"Fn::GetAtt": ["DemoWebAcl", "Arn"]}]
      and $distribution.WebACLId == {"Fn::GetAtt": ["DemoWebAcl", "Arn"]}
      and ($bucket | has("LoggingConfiguration") or has("WebsiteConfiguration") | not)
      and $bucket.PublicAccessBlockConfiguration == {
          BlockPublicAcls: true, BlockPublicPolicy: true, IgnorePublicAcls: true, RestrictPublicBuckets: true
      }
      and $distribution.Origins[0].DomainName == {"Fn::GetAtt": ["AssetsBucket", "RegionalDomainName"]}
      and $distribution.Origins[0].OriginAccessControlId == {"Fn::GetAtt": ["AssetsOriginAccessControl", "Id"]}
      and $resources.AssetsOriginAccessControl.Properties.OriginAccessControlConfig.SigningBehavior == "always"
      and ($grants | length == 1)
      and $grants[0].Action == "s3:GetObject"
      and $grants[0].Principal == {Service: "cloudfront.amazonaws.com"}
      and $grants[0].Condition.StringEquals["AWS:SourceArn"] == {"Fn::Sub": $distribution_arn}
' "$repo_root/template-demo-web.json" >/dev/null
printf '%s\n' 'Demo web deployment checks passed.'
