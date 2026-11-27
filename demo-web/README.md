# Electrit Operations demo

The static frontend signs in through GitHub and submits and checks a read-only
TigerBeetle account lookup through the Operations API.

## Hosting and certificate

[The hosting stack](../template-demo-web.json) serves `https://demo.electrit.com/`
through CloudFront. The distribution redirects HTTP to HTTPS and serves
`index.html` at the root. S3 Block Public Access stays enabled, and CloudFront
uses Origin Access Control to sign requests to the bucket's regional REST
endpoint. The bucket policy grants object reads to that distribution.

Deploy this stack in **US East (N. Virginia), `us-east-1`**, using the AWS
profile authorized to manage the demo. Keep the existing `electrit-demo` Worker,
its deployed version, and the `demo.electrit.com` Worker Custom Domain live
through AWS verification. The [legacy configuration](../cloudflare.config.ts)
records the Worker settings for rollback.

1. Check ACM in `us-east-1` in the AWS account that will own the distribution.
   Reuse an **Issued** public certificate that covers `demo.electrit.com`,
   including a certificate for `*.electrit.com`.
2. If you need a certificate, use an existing pending request or request a
   public certificate for `demo.electrit.com` with DNS validation. Add ACM's
   validation CNAME in Cloudflare if it is missing. Use the exact name and
   target from ACM, set it to **DNS only**, and ensure it is returned without
   flattening. Wait for ACM to show **Issued**. Keep the validation CNAME in
   Cloudflare for ACM renewal. It is separate from the live site record.
3. Use the issued certificate's ARN when deploying the CloudFormation stack.
   The stack adds the alternate domain to CloudFront. Live site DNS still
   points to the Worker.

See the [ACM DNS validation guide](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html),
[Cloudflare's flattening settings](https://developers.cloudflare.com/dns/cname-flattening/set-up-cname-flattening/),
and [CloudFront certificate requirements](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html).

Run the hosting and publishing commands from the repository root after AWS
deployment is authorized. Use a current AWS CLI v2. For a new stack, create
the distribution, private bucket, and WAF web ACL with
`EnableFreePricingPlan=false`. This uses pay-as-you-go pricing for CloudFront
and the attached WAF web ACL. S3 has separate charges. Keep this setting and
continue to publishing if you choose pay-as-you-go.

```sh
export AWS_PROFILE='<profile>'
export DEMO_WEB_STACK_NAME=electrit-demo-web
certificate_arn='<issued-acm-certificate-arn>'

aws cloudformation deploy --region us-east-1 \
  --stack-name "$DEMO_WEB_STACK_NAME" \
  --template-file template-demo-web.json \
  --parameter-overrides CertificateArn="$certificate_arn" EnableFreePricingPlan=false
```

Wait for the distribution to show `Deployed`. Use the same shell for the
stack output lookups below.

```sh
web_output() {
  aws cloudformation describe-stacks --region us-east-1 \
    --stack-name "$DEMO_WEB_STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text
}

aws cloudfront wait distribution-deployed --region us-east-1 \
  --id "$(web_output DistributionId)"
```

## Optional CloudFront Free flat-rate plan

For the **Free ($0/month)** tier, confirm that the account is eligible and has
a free plan slot. After the distribution is deployed, update the same stack
with `EnableFreePricingPlan=true`. The template subscribes the distribution
and its dedicated CloudFront-scope WAF web ACL. S3 requests and the Operations
API can incur separate charges. See
[AWS eligibility and coverage](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html)
and the [CloudFormation subscription reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-pricingplanmanager-subscription.html).

```sh
aws cloudformation deploy --region us-east-1 \
  --stack-name "$DEMO_WEB_STACK_NAME" \
  --template-file template-demo-web.json \
  --parameter-overrides CertificateArn="$certificate_arn" EnableFreePricingPlan=true
```

Verify the plan in the CloudFront console or query the subscription. The CLI
result should show `CloudFront`, `FREE`, and `ACTIVE`. Keep
`EnableFreePricingPlan=true` for later stack updates.

```sh
aws pricing-plan-manager get-subscription --region us-east-1 \
  --arn "$(web_output PricingPlanArn)" \
  --query 'subscription.[planFamily,planTier,status]' --output text
```

If the initial stack creation failed, inspect the CloudFormation events in
`us-east-1`. To reuse the same name after `ROLLBACK_COMPLETE`, delete the
rolled-back frontend stack, wait for deletion to finish, and start with
`EnableFreePricingPlan=false`. If the subscription update fails and the stack
returns to `UPDATE_ROLLBACK_COMPLETE`, the existing hosting resources stay in
place on pay-as-you-go. Continue to publishing on that billing mode or inspect
the `FreePricingPlan` event and check eligibility before retrying the update.
Keep the demo on the Worker until the AWS checks pass.

## Publish assets

The [publish script](../deploy-demo-web.sh) uses Bash, AWS CLI, `jq`, and `file`.
It finds the bucket and distribution in the stack outputs. The publishing role
requires `cloudformation:DescribeStacks` on the stack, `s3:PutObject` on its
asset objects, and `cloudfront:CreateInvalidation` and
`cloudfront:GetInvalidation` on the distribution.

```sh
./deploy-demo-web.sh
```

The script uploads `index.html`, `style.css`, `sign-in.js`, and regular files
below `assets/`, matching [.assetsignore](.assetsignore). It sets content types
explicitly and uploads the entry point after its dependencies. Browsers
revalidate the fixed filenames on reuse. CloudFront caches them for up to an
hour and the script waits for a `/*` invalidation after all uploads succeed.
Publish one revision at a time. If publishing fails, rerun from the same
revision to complete the upload and invalidation. Remove retired objects from
the dedicated bucket explicitly and invalidate their CloudFront paths.

## GitHub browser sign-in and callback privacy

Keep `GITHUB_OAUTH_CALLBACK_URL` and the GitHub OAuth App authorization callback
set to `https://api.electrit.com/auth/github/callback`. Keep
`https://demo.electrit.com/` in the `GITHUB_BROWSER_REDIRECT_URIS` JSON array
and `https://demo.electrit.com` in the comma-separated
`OPERATIONS_BROWSER_ORIGINS` setting. The app uses `https://api.electrit.com`
for authorization, redemption, and Operations requests. If the API origin
changes separately, update both the `operations-api-origin` meta tag and
`connect-src` in `index.html`. See the
[browser sign-in and CORS setup](../docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#browser-sign-in-and-cors).

On the HTTPS callback, CloudFront serves the root document without redirecting
the browser. The browser retains the query string until the app removes
`code`, `state`, and `error` with `history.replaceState`. CloudFront excludes
the query from its cache key and its requests to S3. Keep CloudFront standard
(legacy and v2) and real-time access logs, S3 server access logs, and WAF request
logging and sampling disabled for this site. The page sends no referrer.
The app keeps the PASETO in memory and clears the temporary OAuth state and
PKCE verifier from tab storage when it handles the callback.

## Verify AWS before cutover

1. Publish the assets and wait for the distribution to finish deploying.
   Verify the intended billing mode, the attached ACM certificate, and the
   distribution's Logging tab and behavior settings. Check that the default
   behavior uses the stack cache policy with query strings excluded and has no
   origin request policy. Check that S3 access logging and WAF request logging
   and sampling are off.
2. Test CloudFront directly using the production hostname for TLS and the HTTP
   Host header. `--connect-to` changes only the destination of these requests.
   Expect `200` with the same HTML for both synthetic callback forms and the
   plain root. Check the CSS and JavaScript responses against the published
   files. Use synthetic values for any URL probe.

   ```sh
   distribution_domain="$(web_output DistributionDomainName)"
   (
     set -eu
     probe_dir="$(mktemp -d)"
     trap 'rm -rf "$probe_dir"' EXIT
     probe() {
       status="$(curl --disable --noproxy '*' --silent --show-error --fail \
         --connect-to "demo.electrit.com:443:$distribution_domain:443" \
         --output "$probe_dir/$2" --write-out '%{http_code}' \
         "https://demo.electrit.com$1")"
       test "$status" = 200
     }
     probe / index.html
     probe '/?code=synthetic&state=synthetic' approved.html
     probe '/?error=access_denied&state=synthetic' denied.html
     probe /style.css style.css
     probe /sign-in.js sign-in.js
     cmp "$probe_dir/index.html" "$probe_dir/approved.html"
     cmp "$probe_dir/index.html" "$probe_dir/denied.html"
     for asset in index.html style.css sign-in.js; do
       cmp "$probe_dir/$asset" "demo-web/$asset"
     done
   )
   ```

3. Confirm that an anonymous request to the bucket returns `403`.

   ```sh
   curl --disable --noproxy '*' --silent --show-error --output /dev/null \
     --write-out '%{http_code}\n' "https://$(web_output AssetsBucketDomainName)/index.html"
   ```

   Verify that the API CORS preflight for `https://demo.electrit.com` succeeds
   using the [browser access checks](../docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#verify-browser-access).

## DNS cutover and rollback

1. Record the current Worker deployment and Custom Domain settings in
   Cloudflare. Complete the AWS checks above with traffic still on the Worker.
2. After cutover is authorized, detach only the `demo.electrit.com` Custom
   Domain from the Worker. Remove any conflicting DNS record left for that
   hostname and create a **DNS-only** CNAME named `demo` targeting the
   `DistributionDomainName` stack output. Leave the zone, ACM validation
   CNAME, and API DNS in place. Keep the Worker and its deployed assets.
3. Verify the new DNS answer and run the smoke test below. The Worker Custom
   Domain manages its own DNS record. For rollback, remove the CloudFront
   CNAME and reattach `demo.electrit.com` to the existing Worker in
   **Workers & Pages → electrit-demo → Settings → Domains & Routes**. Wait for
   the binding and TLS to become active and allow for cached DNS answers.
   Keep CloudFront running during DNS propagation and repeat the smoke test
   against the restored Worker.

See [Cloudflare Worker Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)
and [Cloudflare DNS proxy status](https://developers.cloudflare.com/dns/proxy-status/).

### Post-deployment smoke test

1. Confirm `http://demo.electrit.com/` redirects to HTTPS and
   `https://demo.electrit.com/` serves the expected page, CSS, and JavaScript
   without TLS errors.
2. In a fresh browser tab, choose **Sign in with GitHub** and approve access.
   Verify the browser returns to `https://demo.electrit.com/`, clears the
   callback parameters, and signs in after a successful
   `POST https://api.electrit.com/auth/github/redeem`. Check for CORS errors
   without copying credential-bearing requests or URLs.
3. Choose **Open account lookup**, enter a known decimal TigerBeetle account ID,
   and select **Submit lookup**. Use **Check Operation** until the Operation
   completes and confirm that it returns the expected account. After an
   uncertain submission, **Retry submission** keeps its original UUID and
   input. Reloading or signing out ends the session in the tab.

## Cloudflare Web Analytics

The DNS-only CNAME takes the demo out of Cloudflare's HTTP proxy, so automatic
beacon injection and same-origin `/cdn-cgi/rum` reporting stop for CloudFront
traffic. The CloudFront page has no analytics beacon, and its Content Security
Policy no longer allows the Cloudflare beacon. The deployed Worker can resume
automatic injection if traffic rolls back to it. Cloudflare offers manual
beacon installation for DNS-only sites. That requires a separate decision about
the beacon's access to the callback URL and changes to the page and its policy.
See [Cloudflare Web Analytics setup](https://developers.cloudflare.com/web-analytics/get-started/).

## Local preview

Preview the layout from the repository root with a local static server.

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory demo-web
```

Open `http://127.0.0.1:8000/`. Live sign-in requires the registered HTTPS
callback and allowed origin.

The demo bundles the [upstream WOFF2] for Barlow Condensed SemiBold under the
[SIL Open Font License](assets/OFL.txt).

[upstream WOFF2]: https://github.com/jpt/barlow/blob/main/fonts/woff2/BarlowCondensed-SemiBold.woff2
