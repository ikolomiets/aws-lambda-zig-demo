# Electrit Operations demo

The static frontend signs in through GitHub and submits and checks a read-only
TigerBeetle account lookup through the Operations API.

## Hosting

Cloudflare Workers Static Assets serves the demo at `https://demo.electrit.com/`.
The [Cloudflare configuration](../cloudflare.config.ts) assigns the custom
domain to the `electrit-demo` Worker. The
[asset allowlist](.assetsignore) selects the public files.

From the repository root, use the Cloudflare CLI with access to the
`electrit.com` zone.

```sh
cf auth login
cf deploy ./demo-web
```

The exact browser callback is
`https://demo.electrit.com/`. The page derives this URL from its origin and
always uses the root path. Preserve the callback query string through any
hosting redirects. Keep query strings out of access logs for this host.

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
