# Electrit Operations demo

The static frontend signs in through GitHub and submits and checks a read-only
TigerBeetle account lookup through the Operations API.

## Hosting

Cloudflare Workers Static Assets serves the demo at `https://demo.electrit.com/`.
The [Cloudflare configuration](../cloudflare.config.ts) records the hosting
settings for the `electrit-demo` Worker and its custom domain. The
[deployment script](../deploy-demo-web.sh) publishes a new version to that
existing Worker using the [Workers API](https://developers.cloudflare.com/workers/static-assets/direct-upload/).
Set up the Worker and its custom domain in Cloudflare before the first run.

The script uses Bash, `curl`, `jq`, `file`, `shasum`, and `base64`. It publishes
`index.html`, `style.css`, `sign-in.js`, and regular files below `assets/`,
matching the public paths in [.assetsignore](.assetsignore).

Find the [account ID](https://developers.cloudflare.com/fundamentals/account/find-account-and-zone-ids/)
for the Worker and [create a Cloudflare API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
with **Workers Scripts Write** for that account. Export `CLOUDFLARE_ACCOUNT_ID`
and `CLOUDFLARE_API_TOKEN` in the shell that runs the script. In Bash or Zsh,
paste the token when `read` waits for input and press Enter.

```bash
export CLOUDFLARE_ACCOUNT_ID='<account-id>'
read -rs CLOUDFLARE_API_TOKEN
export CLOUDFLARE_API_TOKEN
./deploy-demo-web.sh
unset CLOUDFLARE_API_TOKEN
```

The exact browser callback is
`https://demo.electrit.com/`. The page derives this URL from its origin and
always uses the root path. Preserve the callback query string through any
hosting redirects. Keep query strings out of access logs for this host.

Cloudflare Web Analytics injects its beacon on the hosted demo. The page's
Content Security Policy allows the beacon script and same-origin reporting to
`/cdn-cgi/rum`. In browser DevTools, check that the script loads and the
reporting request succeeds.

The frontend defaults to `https://api.electrit.com`. If the deployed API uses
another host, update both the `operations-api-origin` meta tag and the
`connect-src` directive in `index.html`. Use the same HTTPS API origin for
authorization, redemption, and Operations requests.

Set `GITHUB_OAUTH_CALLBACK_URL` to the API origin plus
`/auth/github/callback` and register that exact URL with the GitHub OAuth App.
Include `https://demo.electrit.com/` in the `GITHUB_BROWSER_REDIRECT_URIS`
JSON array and `https://demo.electrit.com` in the comma-separated
`OPERATIONS_BROWSER_ORIGINS` deployment setting. See
[Browser sign-in and CORS](../docs/DEPLOY_AWS_LAMBDA_WITH_SAM.md#browser-sign-in-and-cors)
for the full setup.

## Use and validation

Preview the layout from the repository root with a local static server.

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory demo-web
```

Open `http://127.0.0.1:8000/`. Live sign-in requires the registered HTTPS
callback and allowed origin. On the registered host, choose **Sign in with
GitHub** and approve access. After returning, open the account lookup, enter
a known decimal account ID, and use **Check Operation** to read the current
state. The Operation can remain submitted while processing is in progress.
After an uncertain submission, **Retry submission** retains its original
UUID and input. Reloading or signing out ends the session in this tab.

The PASETO stays in memory. The tab stores only the temporary state and PKCE
verifier during navigation, then clears them and removes sign-in parameters
from the callback URL before redemption.

The demo bundles the [upstream WOFF2] for Barlow Condensed SemiBold under the
[SIL Open Font License](assets/OFL.txt).

[upstream WOFF2]: https://github.com/jpt/barlow/blob/main/fonts/woff2/BarlowCondensed-SemiBold.woff2
