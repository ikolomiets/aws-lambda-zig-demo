# Operations API Gateway specification

This document specifies the public HTTP boundary for Operation submission,
querying, and GitHub authentication, including its AWS integration.
The [ingress ADR](adr/0008-api-gateway-operation-ingress.md) records the design
trade-offs. The [deployment guide](DEPLOY_AWS_LAMBDA_WITH_SAM.md) owns provisioning,
packaging, infrastructure updates, and cleanup procedures.

The [Operation vocabulary](../GLOSSARY.md),
[identity and hash contract](adr/0001-operation-json-hash-contract.md),
[two-state lifecycle](adr/0002-two-state-operation-state.md), and
[Processor Message contract](adr/0003-minimal-processor-messages.md) define the
domain semantics used here.

## Public HTTP contract

One stack-owned AWS API Gateway HTTP API exposes the common HTTPS origin in the
`OperationsApiUrl` stack output. It uses the AWS-generated hostname, Lambda proxy
payload format 2.0, and the `$default` stage. Paths have no stage or version prefix.
Separate deployments use separate stacks.

| Method and path | Lambda | Successful response |
| --- | --- | --- |
| `POST /operations` | Intake | `200` with the current persisted Operation output view; execution is asynchronous. |
| `GET /operations/{id}` | Query | `200` with the authorized Operation output view, including its Result when completed. |

Both routes are always available. `EnableGitHubExchange=true` adds six named
authentication routes to the same origin and Lambda.

| Method and path | Successful response |
| --- | --- |
| `POST /auth/github/exchange` | `200` with a PASETO |
| `POST /auth/github/device/start` | `200` with device approval instructions |
| `POST /auth/github/device/poll` | `200` with a PASETO after approval |
| `GET /auth/github/authorize` | `302` to GitHub |
| `GET /auth/github/callback` | `302` to the registered app callback |
| `POST /auth/github/redeem` | `200` with a PASETO |

All six routes are absent by default and after disablement. Unsupported public
methods and paths receive a native gateway `404` without a handler invocation,
with Gateway handling CORS preflights when configured. Custom domains and
certificates are managed separately by [api-domain.sh](../api-domain.sh), with
manual Cloudflare DNS.
Gateway response caching is outside the current integration.

Successful responses use `Content-Type: application/json`. Both routes return
bodyless Operation views: `id`, `tenant`, `name`, `state`, `last_updated`,
`expires_at`, and `hash`. A `COMPLETED` view additionally contains `result`;
a `SUBMITTED` view does not. The Result is the existing
`{"type":"SUCCESS|FAILURE","payload":<non-null JSON>}` envelope.

### Authentication and tenant authorization

Both handlers verify PASETO v4.public using `PASETO_PUBLIC_KEY`, configured by the
SAM `PasetoPublicKey` parameter. Each request supplies:

```text
Authorization: Bearer <token>
```

Header names and the Bearer scheme are case-insensitive. Missing, malformed,
expired, or unverifiable credentials receive `401` with
`WWW-Authenticate: Bearer`. Duplicate Authorization headers, including
different-case spellings, and combined bearer values are rejected. The adapter
preserves header ambiguity rather than choosing one credential.

The complete verified `sub` claim is the sole source of Operation Tenant.
Intake and Query treat it as an opaque identifier. Public JSON cannot supply
tenant, lifecycle metadata, hash, Result, Processor Context, or internal routing.
Query looks up the globally keyed Operation UUID and compares the stored tenant
with the verified subject. Missing and foreign Operations return the same
static `404`, including on warm-cache reads.

Authentication runs in the matching Lambda, with no gateway authorizer or
authorization cache. Invalid credentials can therefore invoke the handler.
`LambdaPrincipal` configures an application environment variable; it does not
authenticate HTTP callers or control gateway invocation permissions.

### Direct GitHub exchange

The authentication handler accepts `POST /auth/github/exchange` on the same
HTTPS origin when `EnableGitHubExchange=true`. Exchange is disabled by default.
[Operator setup and enablement](DEPLOY_AWS_LAMBDA_WITH_SAM.md#direct-github-token-exchange)

```http
POST /auth/github/exchange HTTP/1.1
Host: <Operations API host>
Authorization: Bearer <GitHub OAuth App user access token>
Content-Length: 0
```

Send exactly one Bearer credential and an empty body. The GitHub user access
token must have been issued to the deployment's configured OAuth App. GitHub
checks the token on every exchange. The handler uses the verified GitHub
account ID as the Operation Tenant, so account 42 receives `github:42`
even if its GitHub login changes.

A successful exchange returns `200` with `Cache-Control: no-store`.
The JSON body has three fields.

```json
{"access_token":"<PASETO>","token_type":"Bearer","expires_in":28800}
```

Use that PASETO as the Bearer credential for submitting and querying Operations.
It expires eight hours after issuance by default. To obtain another PASETO, make
a fresh exchange with a currently valid GitHub token for the same OAuth App.
The response contains only the PASETO and its type and lifetime. Revoking a
GitHub token prevents new exchanges with it, while already issued PASETOs
continue to work until their signed expiration.

| Status | Direct exchange outcome |
| --- | --- |
| `400` | The authenticated request contains a body. |
| `401` | The credential is missing, ambiguous, malformed, rejected by GitHub, or issued to another OAuth App. The response includes `WWW-Authenticate: Bearer`. |
| `404` | Exchange is disabled. API Gateway returns its native unmatched-route response. |
| `503` | GitHub is unavailable, rate-limits the token check, or returns unusable identity data, or secret retrieval is temporarily unavailable. Wait and retry with backoff. |
| `500` | The exchange has a configuration failure, such as rejected OAuth App credentials, a missing secret, or an invalid or mismatched PASETO signing key. |

### Headless GitHub sign-in

On an HTTPS Operations API origin with device sign-in enabled, a client can sign
in using only that origin. The authentication Lambda uses the deployment's GitHub
OAuth App and requests zero scopes. Enable device flow in the GitHub OAuth App
registration. [Operator setup](DEPLOY_AWS_LAMBDA_WITH_SAM.md#device-sign-in-binding)

1. Send an empty request to the Operations origin.

   ```http
   POST /auth/github/device/start HTTP/1.1
   Host: <Operations API host>
   Content-Length: 0
   ```

   A successful start returns `200` with `Cache-Control: no-store`. The JSON
   body contains these fields.

   ```json
   {
     "device_code": "<private Operations device code>",
     "user_code": "WDJB-MJHT",
     "verification_uri": "https://github.com/login/device",
     "interval": 5,
     "expires_in": 899
   }
   ```

2. Show the person `verification_uri` and `user_code`. Ask them to open the
   URI in a browser, enter the code, and approve the OAuth App in GitHub.
   Keep the private `device_code` in memory. Send it only to the same
   Operations HTTPS origin in the poll body. Keep it out of URLs, logs,
   and diagnostic output.

3. Wait at least `interval` seconds before the first poll. Stop polling
   when the returned `expires_in` seconds have elapsed.

   ```http
   POST /auth/github/device/poll HTTP/1.1
   Host: <Operations API host>
   Content-Type: application/json
   Content-Length: <JSON body length in bytes>

   {"device_code":"<private Operations device code>"}
   ```

   Poll responses include `Cache-Control: no-store`.

   | Status | Poll outcome and client action |
   | --- | --- |
   | `202` | `{"error":"authorization_pending","interval":5}` means approval is pending. Wait at least the returned interval before polling again. |
   | `429` | `{"error":"slow_down"}` with `Retry-After` in seconds means the next poll must wait at least that long. This applies both to an early poll and to a GitHub slowdown. For a gateway throttle without this header, back off. |
   | `403` | `{"error":"access_denied"}`. Stop and report that approval was denied. Start again if the person wants to retry. |
   | `410` | `{"error":"expired_or_consumed"}`. Discard the code. Start a new sign-in if credentials are still needed. |
   | `400` | The poll body is invalid. Send a JSON object containing only the private Operations device code. |
   | `503` | An upstream service or storage operation is temporarily unavailable. Retry with backoff within the grant lifetime. |
   | `500` | The server cannot complete sign-in. Report the status without including credentials. |

4. On approval, the first successful poll returns `200` with the PASETO response.

   ```json
   {"access_token":"<PASETO>","token_type":"Bearer","expires_in":28800}
   ```

   Discard the device code and use the PASETO as the Bearer credential for
   [Operation requests](#authentication-and-tenant-authorization). The PASETO
   expires eight hours after issuance by default. When it expires, discard it
   and begin a new sign-in at step 1.

Operations verifies the approved GitHub token against the configured OAuth App,
uses the numeric GitHub account ID to resolve the Operation Tenant, and discards
the GitHub token. Pending Sign-ins survive separate Lambda invocations. The
server enforces the GitHub grant deadline even while the DynamoDB row still
exists. A successful conditional write consumes the grant before PASETO
issuance. [GitHub device flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow)

#### Sign in from a terminal

From the checkout, build the host CLI with `zig build build-paseto`. Set
`OPERATIONS_API_URL` to the HTTPS origin of a deployment with device sign-in
enabled. When the CLI prompts on stderr, open the displayed URL, enter the
displayed user code, and approve the OAuth App in GitHub. The command puts the
PASETO on stdout so the shell can capture it. Use the UUID of an existing
Operation owned by that GitHub account. [Endpoint discovery](#calling-the-api-and-discovering-endpoints)

```sh
export OPERATIONS_API_URL='https://api.example.com'
operation_id='<operation-uuid>'
token="$(zig-out/bin/paseto login github)" &&
  curl --fail-with-body -H "Authorization: Bearer $token" \
    "${OPERATIONS_API_URL%/}/operations/$operation_id"
```

The PASETO expires eight hours after issuance by default. Discard the old token
and run `paseto login github` again to sign in and get a fresh token.

### Browser GitHub sign-in

Browser sign-in uses the opt-in authentication Lambda and its Pending Sign-in
table. Configure the Operations OAuth callback and the app callback URLs to
enable the browser flow. For a browser app hosted separately from the API,
configure its origin for cross-origin requests.
[Operator setup](DEPLOY_AWS_LAMBDA_WITH_SAM.md#browser-sign-in-and-cors)

The Lambda reads `GITHUB_OAUTH_CALLBACK_URL` for the HTTPS Operations callback
registered with GitHub. Use the callback URL without a query or fragment.
`GITHUB_BROWSER_REDIRECT_URIS` is a JSON array of exact
HTTPS app callback URLs. The comparison uses the decoded `redirect_uri` value
byte for byte, including any static query string. A registered app callback
cannot contain user information, a fragment, or a query parameter named `code`,
`state` or `error`. Callback registration and cross-origin access are separate
settings.

1. Generate fresh random app state and an independent PKCE verifier using the
   browser's cryptographic random source. A base64url encoding of 32 random
   bytes without padding gives a 43-character verifier. Compute the challenge
   as base64url without padding of the SHA-256 digest of the verifier's ASCII
   bytes. Keep only the temporary state and verifier in `sessionStorage` for
   this tab. Use a top-level navigation to `GET /auth/github/authorize` with
   `redirect_uri`, `state`, `code_challenge` and `code_challenge_method=S256` as
   URL-encoded query parameters.
2. Operations validates the app callback and responds with a `302` to GitHub
   requesting zero scopes. It uses its own state and S256 challenge with GitHub
   and binds the Pending Sign-in to a short-lived Secure, HttpOnly, SameSite=Lax
   cookie on the Operations host. On GitHub's redirect to
   `GET /auth/github/callback`, the browser sends the cookie as proof that it
   initiated the Pending Sign-in. Operations checks that proof and its upstream
   state before exchanging GitHub's code with its own verifier. It resolves the
   Operation Tenant from the verified GitHub account and discards the GitHub
   token.
3. Operations redirects to the app callback with `code` and the app's original
   `state`, or with `error=access_denied` and the same state on denial. Read the
   result and require exactly one state matching the app state in
   `sessionStorage` before acting on either outcome. Remove the returned fields
   from the address bar with `history.replaceState` before making other
   requests. For a valid approval, read the app verifier from `sessionStorage`
   and send `POST /auth/github/redeem` to Operations with this JSON body.

   ```json
   {
     "code": "<Operations code>",
     "redirect_uri": "<original registered HTTPS callback>",
     "code_verifier": "<app verifier from tab storage>"
   }
   ```

4. On first valid redemption, Operations conditionally consumes the grant and
   returns `200` with only `access_token`, `token_type` (`Bearer`) and
   `expires_in` (28,800 seconds by default). Clear the state and verifier on
   completion or denial. Discard any old attempt before beginning a new one.
   Hold the PASETO in memory and use it for authorized Operation requests. Local
   sign-out discards that in-memory copy. A reload requires fresh sign-in. Any
   other copy remains valid up to its signed expiration.

The authentication responses use `Cache-Control: no-store`. A malformed or
unregistered request or invalid callback binding fails locally. A PASETO or
GitHub access token never appears in a redirect. Keep codes, state, verifiers,
cookies and credential-bearing URLs out of application diagnostics. Denial
ends the attempt. A callback already claimed for GitHub exchange stays spent
even if the exchange fails. Start a fresh sign-in in that case.

The callback must complete within ten minutes of authorization. The code
expires 60 seconds after the callback verifies GitHub's identity, capped by
the original ten-minute deadline. The server checks both cutoffs on access
even while the rows remain stored. Invalid redemption input or an app binding
mismatch returns `400`. An expired or consumed code returns `410`.
[GitHub OAuth web application flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#web-application-flow)

#### Cross-origin requests

CORS is off by default. An enabled GitHub deployment can set
`OperationsBrowserOrigins` to an explicit comma-separated list of HTTPS
origins. The HTTP API answers preflights for `GET`, `POST`, and `OPTIONS`
with `Authorization` and `Content-Type` allowed. Gateway grants the configured
origins access to integration responses for sign-in, submission and query,
and exposes `Retry-After` when the handler provides it. Unlisted origins
receive no cross-origin read permission. API Gateway applies this policy.
[HTTP API CORS](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-cors.html)

Use top-level navigation for authorization and the GitHub callback. The
Operations binding cookie is sent on that navigation. Use credential-free
CORS fetches for redemption and send the issued PASETO explicitly in the
Authorization header for submission and query. CORS checks the calling origin.
Browser sign-in separately requires the exact registered callback URL and its
PKCE proof, and Intake and Query still verify the PASETO.
[Browser caller example](#browser-caller-example)

#### Browser caller example

The [static browser demo](../demo-web/README.md) implements this sign-in and
lookup flow for the dedicated demo host.

Serve this HTML at an exactly registered app callback, such as
`https://app.example.com/sign-in.html`, and allow `https://app.example.com`
as an origin. Replace the example API origin, callback and lookup account
with values for your deployment. After signing in, choose **Submit and query
a lookup** to submit one TigerBeetle lookup and read the Operation's current
view. Choose **Sign out** to discard the in-memory PASETO and stop the app
from sending authenticated requests. Reloading also requires fresh sign-in.
Only the PKCE verifier and app state go into tab-scoped storage during the
redirect. The app clears them on completion or denial. An independently held
PASETO stays usable until its original signed expiration.

```html
<!doctype html>
<meta charset="utf-8">
<meta name="referrer" content="no-referrer">
<title>Operations sign-in example</title>
<button id="sign-in">Sign in with GitHub</button>
<button id="run-lookup" disabled>Submit and query a lookup</button>
<button id="sign-out" disabled>Sign out</button>
<pre id="result"></pre>
<script type="module">
const api = "https://api.example.com";
const callback = "https://app.example.com/sign-in.html";
const attemptKey = "operations-sign-in";
const signInButton = document.querySelector("#sign-in");
const lookupButton = document.querySelector("#run-lookup");
const signOutButton = document.querySelector("#sign-out");
const output = document.querySelector("#result");
let token = null;

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function beginSignIn() {
  sessionStorage.removeItem(attemptKey);
  const state = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  sessionStorage.setItem(attemptKey, JSON.stringify({ state, verifier }));
  const authorize = new URL("/auth/github/authorize", api);
  authorize.search = new URLSearchParams({
    redirect_uri: callback,
    state,
    code_challenge: base64url(new Uint8Array(digest)),
    code_challenge_method: "S256",
  });
  location.assign(authorize);
}

async function request(path, options) {
  const response = await fetch(api + path, { ...options, credentials: "omit" });
  if (!response.ok) throw new Error(`Operations returned HTTP ${response.status}`);
  return response.json();
}

async function finishSignIn(params) {
  const saved = sessionStorage.getItem(attemptKey);
  sessionStorage.removeItem(attemptKey);
  // Restore the registered callback URL, including any static query.
  history.replaceState(null, "", callback);
  const attempt = saved && JSON.parse(saved);
  if (!attempt || params.getAll("state").length !== 1 ||
      params.get("state") !== attempt.state) {
    throw new Error("Sign-in state did not match");
  }
  if (params.has("error")) throw new Error("GitHub sign-in was denied");
  if (params.getAll("code").length !== 1 || !params.get("code")) {
    throw new Error("Missing or ambiguous sign-in code");
  }
  const { access_token } = await request("/auth/github/redeem", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      code: params.get("code"),
      redirect_uri: callback,
      code_verifier: attempt.verifier,
    }),
  });
  token = access_token;
  lookupButton.disabled = false;
  signOutButton.disabled = false;
  output.textContent = "Signed in.";
}

async function runLookup() {
  if (!token) return;
  lookupButton.disabled = true;
  try {
    const submitted = await request("/operations", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        id: crypto.randomUUID(),
        name: "TigerBeetle",
        body: { lookup_accounts: [{ id: "101" }] },
      }),
    });
    if (!token) return;
    const current = await request(`/operations/${encodeURIComponent(submitted.id)}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (token) output.textContent = JSON.stringify(current, null, 2);
  } catch (error) {
    if (token) showError(error);
  } finally {
    lookupButton.disabled = !token;
  }
}

function showError(error) {
  output.textContent = error instanceof Error ? error.message : "Request failed";
}

function showSignInError(error) {
  showError(error);
  signInButton.disabled = false;
}

signInButton.addEventListener("click", () => {
  signInButton.disabled = true;
  beginSignIn().catch(showSignInError);
});
lookupButton.addEventListener("click", runLookup);
signOutButton.addEventListener("click", () => {
  token = null;
  lookupButton.disabled = true;
  signOutButton.disabled = true;
  signInButton.disabled = false;
  output.textContent = "Signed out. Sign in to continue.";
});
const params = new URLSearchParams(location.search);
if (["code", "state", "error"].some((name) => params.has(name))) {
  signInButton.disabled = true;
  finishSignIn(params).catch(showSignInError);
}
</script>
```

### Submission, paths, and request bodies

Submission accepts the existing Operation input JSON containing `id`, `name`, and
`body`. Name-based queue selection uses the exact `<name>Queue` environment
mapping; unknown, reserved, or unconfigured names fail existing validation.
The same ingress rules apply to TigerBeetle and SeatReservation Operations.
Their Body schemas belong to the [processor reference](TIGER_BEETLE_PROCESSOR.md)
and [seat reference](SEAT_RESERVATION.md).

Query extracts its UUID exclusively from the exact application path
`/operations/{id}`. Uppercase hexadecimal is accepted and normalized in output.
Malformed UUIDs, extra segments, trailing slashes/content, and percent-encoded
UUID paths fail application validation. There is no additional URL-decoding pass.
Query strings, GET bodies, `pathParameters`, and `routeKey` cannot supply or
replace the ID. A path that does not match the gateway route is rejected there
before application validation.

For a valid AWS envelope, handlers authenticate first, validate the method next,
and only then access and validate the submission body. Query never reads a body.
The adapter decodes standard base64 only when body access is requested and
`isBase64Encoded` is true. Equivalent plain and base64 representations have the
same application behavior. Missing submission bodies and malformed base64
receive `400` after authentication and method checks. Allocation/internal failures
remain server errors.

The 4,096-byte bound applies to the caller's serialized Operation Body fragment,
including escaping and internal whitespace. A valid Body at that boundary is
accepted inside a larger Operation envelope; a 4,097-byte Body is rejected.
There is no additional application-wide limit on the complete envelope. AWS
transport limits apply independently.

Transport adaptation preserves decoded JSON bytes without normalization or
reserialization. Existing Operation validation rejects duplicate decoded keys
and server-owned input fields. Existing hash normalization remains authoritative:
insignificant whitespace and equivalent string escapes compare equally, while
object key order affects the hash. Valid JSON remains acceptable with missing or
differing Content-Type; there is no media-type gate or new `415` response.

### Idempotency, Completion, and caching

Operation UUIDs are globally scoped. The stable hash covers verified tenant,
name, and Body. Reusing a UUID with another tenant or different work returns
`409 Conflict`.

A matching retry of a `SUBMITTED` Operation republishes its Processor Message;
a matching `COMPLETED` retry returns the stored view without another send.
Uncertain or failed queue publication leaves the persisted item `SUBMITTED` and
returns static `503`, allowing retry with the original input. Delivery remains
at least once. Stable Operation UUIDs do not provide exactly-once execution;
native Resource IDs and replay obligations remain part of the processor contract.

The lifecycle is `SUBMITTED -> COMPLETED`, with an immutable terminal Result.
The HTTP integration does not change persistence schemas, Processor Messages,
name-based routing, domain execution, or Completion ownership.

Query retains a one-second process-local cache with capacity for 1,024 Operations.
Cache misses use strongly consistent DynamoDB reads. Authentication and tenant
checks apply to every request; cached views can lag Completion until expiry.
There is no gateway response cache. DynamoDB TTL is asynchronous: an expired
item remains readable while it is still stored.

### Error responses and retry behavior

Handler errors are static plain text with `Content-Type: text/plain; charset=utf-8`.
Gateway rejections and integration failures keep their native response formats;
clients cannot assume a common gateway/handler error-body schema.

| Status | Boundary and meaning |
| --- | --- |
| `400` | Handler: invalid Operation input/body encoding, missing submission body, or invalid Query UUID/path that reaches Query. |
| `401` | Handler: rejected credentials; includes `WWW-Authenticate: Bearer`. |
| `404` | Query: missing or foreign Operation. Gateway: unmatched method/path, with a separate native response. |
| `405` | Direct application/adapter invocation: wrong or missing method after authentication; `Allow: POST` for Intake or `Allow: GET` for Query. Unsupported public methods receive gateway `404`. |
| `409` | Intake: conflicting UUID reuse. |
| `429` | Gateway: throttled before Lambda invocation. |
| `503` | Intake: queue publication failure/uncertainty. Query: DynamoDB request/service failure. |
| `500` | Handler: configuration, allocation, malformed persisted data, and other unexpected failures, with sanitized output. AWS response-encoding failure has a sanitized fallback. |

After `429`, callers increase delay and add jitter before retrying submissions or
polling. After a submission timeout, lost response, or other uncertain outcome,
retain the same UUID, verified tenant, name, and original Body. Poll and retry
with that identity; keep the original input available. A submitted retry can
republish work. The repository defines no new SDK or automatic retry policy.

## AWS integration and ownership

[template.yaml](../template.yaml) owns `OperationsApi`, its generated default
stage, Lambda proxy integrations, and the common URL output.
The inline OpenAPI definition is the infrastructure routing declaration;
the application contract is specified above.

| Resource | Contract |
| --- | --- |
| `IntakeApiPermission` | `lambda:InvokeFunction` for `apigateway.amazonaws.com`, scoped to the stack account and this API's `$default/POST/operations`. |
| `QueryApiPermission` | Same service/account scope, restricted to this API's `$default/GET/operations/*`. |
| Authentication invocation grants | One grant for each enabled authentication method and path, scoped to this API's `$default` stage, service and account. |
| `OperationsApiAccessLogGroup` | Stack-owned log destination, seven-day retention, deletion on stack deletion or replacement. |
| `OperationsApiAccessLogPolicy` | Stack-owned service log-delivery permission, created before the API/stage and deleted with the stack or on replacement. |

The stack declares no public Lambda Function URLs or public URL/invocation grants.
`OperationsApiUrl` is the sole public endpoint output, with no former-output
aliases. Supporting Function URL-shaped events in code does not expose those
URLs. Processors remain SQS-driven.

The delivery policy grants `logs:CreateLogStream` and `logs:PutLogEvents` to
`delivery.logs.amazonaws.com` for this log group's streams, with source account
and Region constraints. It consumes one CloudWatch Logs resource-policy slot
in the account/Region. Deployment needs log-group, retention, resource-policy,
and HTTP API log-delivery setup permissions; Lambda execution roles gain no
log-delivery permissions. See the deployment guide's
[resource contract](DEPLOY_AWS_LAMBDA_WITH_SAM.md#4-understand-what-the-template-creates)
for operational prerequisites.

Full stack deployment owns routes, permissions, throttle settings, logging, and
outputs. `deploy.sh --dev` updates function code only. Gateway configuration
changes require a full stack update. Stack cleanup removes the API, stage,
invocation grants, access-log group, delivery policy, and remaining access-log
records. Existing Lambda application-log retention is a separate policy.

### Application and adapter boundary

| Source | Responsibility |
| --- | --- |
| [http.zig](../src/http.zig) | Application-owned requests and responses, including browser queries, cookies, and deferred request bodies. |
| [aws_http.zig](../src/aws_http.zig) | Payload 2.0 envelope parsing, header preservation, bounded browser query and cookie decoding, deferred body materialization, and AWS response encoding. |
| [intake_lambda.zig](../src/intake_lambda.zig) and [query_lambda.zig](../src/query_lambda.zig) | Lambda entry points and `handle_http` application behavior, including existing persistence/publication seams and warm resource ownership. |
| [lambda_auth.zig](../src/lambda_auth.zig) | Authentication from application headers, environment, allocator, and clock. |

Handlers and authentication do not require provider request/response types,
Lambda context, route keys, or path parameters. Runtime context stays at the
entry points. Operation parsing, queue selection, persistence, and authorization
stay in application modules; the adapter supplies no authenticated identity.

The adapter accepts named-route HTTP API and Function URL payload 2.0 shapes.
It scans envelope JSON without accumulating the body string, so authentication
and method rejection avoid whole-body materialization and base64 decoding.
Malformed AWS envelopes fail before Operation effects. This compatibility uses
the unchanged [pinned Lambda dependency](../build.zig.zon), `lambda.handle`
callback/lifecycle, and `lambda.url.encodeResponse`; the upstream Function URL
request parser's named-route restriction is isolated from the request path.

Request metadata and materialized body bytes remain owned by the adapter request.
Application request fields are borrowed during handling. Response bodies retain
their owner until AWS encoding completes; the entry point then releases them.
Serialization failures use the sanitized static `500` fallback. There is one
concrete adapter, with no transport registry or general server framework.

## Route throttles

The default stage configures the two Operation routes independently.
The authentication routes use the gateway's account and Region throttle limits.

| Route | Rate parameter | Default requests/second | Burst parameter | Default |
| --- | --- | ---: | --- | ---: |
| `POST /operations` | `SubmissionThrottlingRateLimit` | 10 | `SubmissionThrottlingBurstLimit` | 20 |
| `GET /operations/{id}` | `QueryThrottlingRateLimit` | 50 | `QueryThrottlingBurstLimit` | 100 |

All callers share each route's allowance. Targets are best-effort and subject to
account/Region constraints. They are not tenant quotas, hard cost ceilings,
exact rejection thresholds, or guarantees of downstream processing capacity.
No additional aggregate API-wide quota is configured. Processor concurrency is
independent of these settings.

[deploy.sh](../deploy.sh) accepts the corresponding
`SUBMISSION_THROTTLING_RATE_LIMIT`, `SUBMISSION_THROTTLING_BURST_LIMIT`,
`QUERY_THROTTLING_RATE_LIMIT`, and `QUERY_THROTTLING_BURST_LIMIT` environment values.
Its explicit `--submission-throttling-rate-limit`,
`--submission-throttling-burst-limit`, `--query-throttling-rate-limit`, and
`--query-throttling-burst-limit` options take precedence. Rates accept nonnegative
decimals; bursts require nonnegative integers; explicitly empty values fail.

The helper passes all four values on every full deployment, falling back to the
defaults above. It does not inherit saved SAM or deployed throttle values; repeat
custom overrides on later full deployments. `--dev` ignores throttle environment
values and rejects explicit throttle options; `--cleanup` also rejects those
options. Direct SAM deployment uses the four parameter names above. The
[throttle configuration procedure](DEPLOY_AWS_LAMBDA_WITH_SAM.md#route-throttle-configuration)
owns complete deployment examples.

## Calling the API and discovering endpoints

For an already deployed stack, use AWS CLI v2 with stack-read permissions and the
selected profile/Region to discover the common origin. This read-only example
uses the deployment guide's default context:

```sh
STACK_NAME="${STACK_NAME:-aws-lambda-zig-demo}"
OPERATIONS_API_URL="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='OperationsApiUrl'].OutputValue | [0]" \
  --output text --profile "${AWS_PROFILE:-dev}" \
  --region "${AWS_REGION:-ca-central-1}")"
```

The output must be an HTTPS origin, without a route, query string, or fragment.
Check discovery succeeded before sending requests. With the host `paseto` binary
built and `PASETO_PRIVATE_KEY` exported for the deployed public key, issue a token:

```sh
token="$(zig-out/bin/paseto issue --subject 'example-user' --ttl-seconds 300)"
```

The following POST creates work; run it when intentionally exercising a deployed
stack. Use a fresh UUID for new work and retain it with the original input for
retries. This lookup-only example observes TigerBeetle account `101`, independently
of the Operation UUID; a missing account produces a failure Result.

```sh
operation_id='00112233-4455-6677-8899-aabbccddeeff'
curl -i -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  --data '{"id":"00112233-4455-6677-8899-aabbccddeeff","name":"TigerBeetle","body":{"lookup_accounts":[{"id":"101"}]}}' \
  "${OPERATIONS_API_URL%/}/operations"

curl -i -H "Authorization: Bearer $token" \
  "${OPERATIONS_API_URL%/}/operations/$operation_id"
```

POST returns the persisted view; poll GET for Completion using a token with the
same subject. The [authenticated API procedure](DEPLOY_AWS_LAMBDA_WITH_SAM.md#8-test-query-get-and-intake-post)
covers expected views and failures. [events.sh](../events.sh) and
[seat_scenarios.sh](../seat_scenarios.sh) discover the same `OperationsApiUrl`
by default and construct these routes; there is no separate Query origin.

The deployed scenario runner and [Events wrapper](../events.sh) accept
`--api-url https://api.example.com` to select an existing custom domain for their
public HTTP requests. The value must be an HTTPS origin, with an optional trailing
slash and no credentials, path prefix, query string, or fragment. The custom
domain must map to the selected stack's API and stage at the root. AWS resource
discovery still uses the selected stack/profile/Region; the option does not
configure DNS, certificates, or API mappings. The Events wrapper accepts this
option before its HTTP command; `read` accesses DynamoDB directly and rejects it.
Local loopback runtime tests and mocked tests do not use this public origin.

### Standalone custom domain

[api-domain.sh](../api-domain.sh) exposes command-first positional commands:

```sh
./api-domain.sh setup api.example.com --profile dev --region ca-central-1
./api-domain.sh verify api.example.com --profile dev --region ca-central-1
```

Options follow the domain; `--domain` is invalid. Profile and Region options
override `AWS_PROFILE` and `AWS_REGION`, otherwise AWS CLI defaults apply.
`--stack-name` defaults to `STACK_NAME` or `aws-lambda-zig-demo`, `--stage` to
literal `$default`, and `--mapping-key` to the empty root mapping. There is no
hardcoded AWS profile or Region. `--certificate-arn` selects an ACM certificate
for a new domain or asserts the certificate already attached to an existing one.

Setup discovers the stack's HTTP API and validates the requested existing stage.
It reuses a compatible Regional domain and its certificate, or reuses a unique
matching public ACM certificate; ambiguous matches require explicit selection.
If none matches, it requests a DNS-validated public RSA-2048 certificate. Pending
validation returns `3`, prints the full AWS CNAME names and targets for Cloudflare,
and resumes on a subsequent setup. Existing incompatible domains are rejected.
Domains use API mappings only, no mutual TLS, and **`TLS_1_2`**: HTTP APIs accept
TLS 1.2 and TLS 1.3 under this policy. See
[AWS security policies](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-ciphers.html).

The selected mapping is created or repointed to the requested API/stage; other
mappings remain intact. For example, `--stage staging --mapping-key staging`
provides `https://api.example.com/staging/operations`. The gateway strips the
prefix before forwarding to the API. Stages and their Lambda invocation
permissions must already work; the helper changes neither stages nor IAM. The
template's permissions cover `$default` only. The wrappers' `--api-url` option
continues to require a root mapping.

The helper prints permanent ACM validation records and the traffic CNAME using
full record names, AWS targets, **DNS only**, and **TTL Auto**. Cloudflare changes
are manual. Keep ACM's DNS validation records for automatic renewal while the
certificate is in use; imported/email-validated certificates need their own
renewal process. Certificates and domains survive application-stack replacement
or deletion; rerun setup to repoint a mapping after replacement. There is no
deletion command. SAM and `deploy.sh` continue owning the API, routes, stage,
Lambda permissions and generated URL output.

Verify uses only AWS reads, validates the domain, certificate, API/stage and
selected mapping, and rejects competing mappings that shadow probe paths. It
checks public HTTPS with normal certificate validation, a TLS 1.2 minimum, no
upper-version cap, no proxy or redirects, and bounded timeouts. Unauthenticated,
bodyless `POST /operations` and `GET /operations/<uuid>` must return `401` with
`WWW-Authenticate: Bearer`; unsupported `GET /operations` must return `404`.
The selected prefix applies to all probes. No token, Operation body, application
record write or infrastructure change is involved; normal invocation logs and
metrics can be emitted. Success establishes configuration and unauthenticated
routing, not processor execution or asynchronous Completion.

Exit codes are `0` for completed AWS setup or successful verification, `1` for
operational/verification failure, `2` for invalid configuration and `3` for
pending certificate validation or resource readiness. Setup success does not
claim working HTTPS. The [domain deployment procedure](DEPLOY_AWS_LAMBDA_WITH_SAM.md#custom-api-domain-and-cloudflare-dns)
owns operator permissions, manual DNS instructions and stage-switch examples.

Deployment probes in [deploy.sh](../deploy.sh) check unauthenticated `401` on
both matching routes, authenticated missing-Operation `404`, invalid/bodyless
submission `400`, and native gateway `404` on root, unmatched paths, and wrong
methods. A root `404` does not establish authentication is working. These probes
do not establish successful asynchronous Completion.

## Access logs and diagnosis

The API stage writes exactly six fields to its separate access-log group.
Every value is a JSON string, including status and millisecond timings:

| Field | Gateway substitution |
| --- | --- |
| `request_id` | `$context.requestId` |
| `integration_request_id` | `$context.integration.requestId`, when available |
| `route_key` | `$context.routeKey`, the configured method/route template |
| `status` | `$context.status` |
| `response_latency_ms` | `$context.responseLatency` |
| `integration_latency_ms` | `$context.integration.latency`, when available |

The policy excludes credentials, request/response bodies, query strings, client
IP addresses, raw caller paths, and extra client/business identity fields. A
matched route template does not include the caller's Operation UUID. Unmatched
requests can lack route metadata; the format does not fall back to raw paths.

Integration fields can be unavailable for pre-integration `429`/`404` responses,
which have no Lambda invocation. Treat unavailable values as missing; there is
no promised placeholder spelling. Quoted substitutions keep representative
missing-value records valid JSON.

When available, `integration_request_id` supports correlation with the routed
Lambda's START/END/REPORT request ID and structured Intake `lambda_request_id`.
The gateway `request_id` is a separate identifier. These IDs are diagnostic
identifiers, not authorization evidence, and the logs are not a complete audit
ledger or a promise of universal correlation.

Use the deployment guide's [access-log inspection commands](DEPLOY_AWS_LAMBDA_WITH_SAM.md#inspect-api-access-logs)
to discover `OperationsApiAccessLogGroup`, tail records with the selected
stack/profile/Region, and inspect fields in Logs Insights. Reading needs
`cloudformation:DescribeStackResource`, `logs:DescribeLogStreams`, and
`logs:FilterLogEvents` for the documented tail example. Records have seven-day
retention and remaining records are deleted with the stack. Existing Lambda
application-log settings and retention remain separate.

## Validation contract and evidence limits

The [local-check guide](agents/local-checks.md) owns commands, dependency
prerequisites, the complete offline gate, and loopback sandbox permissions.
Relevant existing checks are:

| Check | Evidence |
| --- | --- |
| `zig build test-http --system zig-pkg` | Generic handler/authentication behavior plus separate AWS adapter compatibility tests. |
| `zig build test-paseto-cli --system zig-pkg` | Terminal sign-in exit status and output, polling with a controlled clock and simulated Operations responses, and verification of the returned PASETO. |
| `bash tests/operations_api_test.sh` | Declared routes, payload format, permissions, enablement and disablement, Pending Sign-in table binding and TTL, CORS configuration and mocked deployment/discovery/probes. |
| `bash tests/api_domain_test.sh` | Positional parsing, AWS context, certificate/domain reuse, manual DNS instructions, mapping reconciliation and read-only HTTPS probes with AWS/curl mocked. |
| `bash tests/events_wrapper_test.sh` | Mocked Events integration with common-origin discovery. |
| `bash tests/seat_scenarios_test.sh` | Mocked seat-tool integration with common-origin discovery. |
| `zig build test-runtime --system zig-pkg` | Real Lambda event loop with a fake loopback Runtime API across all seven handlers. The tests cover browser binding, expiry while rows remain, device and browser single-use completion, and DynamoDB conditional updates through the SDK. Intake and Query exercise authenticated and unauthorized browser requests. |
| SAM validation described in the [deployment guide](DEPLOY_AWS_LAMBDA_WITH_SAM.md#3-validate-the-sam-template) | Template validity; no cloud enforcement evidence. |

Required regression coverage includes generic HTTP behavior without AWS metadata;
named-route and Function URL payload 2.0 compatibility; plain/base64 equivalence;
authentication/method/body precedence; ignored Query bodies; malformed/missing
bodies; the 4,096/4,097-byte Body boundary within larger envelopes; escaping,
whitespace, duplicate keys, Content-Type tolerance, and stable hashing; exact
path UUID extraction and ambiguous-header rejection; matching retries, conflict,
publication uncertainty, terminal Results, and cross-tenant warm-cache reads;
allocation/encoding failures, response lifetime, and recovery on later invocations.
Infrastructure coverage includes explicit CORS origins, methods and headers,
catch-all and Function URL absence, and representative valid access-log JSON
when integration fields are unavailable.

Local checks establish application behavior and declared configuration. They do
not establish deployed route or CORS enforcement, effective invocation permissions,
absence of live public Function URLs, actual throttle enforcement, or CloudWatch
receipt/retention. Deployed acceptance requires separately authorized AWS checks
of these properties and representative PASETO/tenant cases. Throttle traffic
experiments must be bounded and cannot assert an exact best-effort rejection
threshold. Inspect cleanup configuration without treating live stack deletion
as an implied test. Record cloud evidence separately from local results.
