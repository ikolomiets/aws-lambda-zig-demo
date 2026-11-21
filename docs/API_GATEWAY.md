# Operations API Gateway specification

This document specifies the implemented public HTTP boundary for Operation
submission and querying, its AWS integration, and caller and operator usage.
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

These are the only public routes. The default stage does not create a `$default`
catch-all route. Unsupported public methods and paths, including the API root,
receive a native gateway `404` without a handler invocation. CORS is disabled;
the API targets non-browser clients. Custom domains and certificates are managed
separately by [api-domain.sh](../api-domain.sh), with manual Cloudflare DNS.
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
HTTPS origin when a deployment exposes the route. The current SAM template
exposes the two Operation routes above.

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
| `503` | GitHub is unavailable, rate-limits the token check, or returns unusable identity data, or secret retrieval is temporarily unavailable. Wait and retry with backoff. |
| `500` | The exchange has a configuration failure, such as rejected OAuth App credentials, a missing secret, or an invalid or mismatched PASETO signing key. |

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
stage, two separate Lambda proxy integrations, and the common URL output.
The inline OpenAPI definition is the infrastructure routing declaration;
the application contract is specified above.

| Resource | Contract |
| --- | --- |
| `IntakeApiPermission` | `lambda:InvokeFunction` for `apigateway.amazonaws.com`, scoped to the stack account and this API's `$default/POST/operations`. |
| `QueryApiPermission` | Same service/account scope, restricted to this API's `$default/GET/operations/*`. |
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
| [http.zig](../src/http.zig) | Application-owned `HttpRequest` (method, path, headers, deferred body access) and `HttpResponse` (status, headers, body). |
| [aws_http.zig](../src/aws_http.zig) | Payload 2.0 envelope parsing, header preservation, deferred body materialization/base64 decoding, and AWS response encoding. |
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

The default stage configures each named route independently:

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
| `bash tests/operations_api_test.sh` | Declared routes, payload format, permissions, output, throttle defaults/overrides, access-log policy/format/lifecycle, and mocked discovery/probes. |
| `bash tests/api_domain_test.sh` | Positional parsing, AWS context, certificate/domain reuse, manual DNS instructions, mapping reconciliation and read-only HTTPS probes with AWS/curl mocked. |
| `bash tests/events_wrapper_test.sh` | Mocked Events integration with common-origin discovery. |
| `bash tests/seat_scenarios_test.sh` | Mocked seat-tool integration with common-origin discovery. |
| `zig build test-runtime --system zig-pkg` | Real Lambda event loop with a fake loopback Runtime API and external effects mocked across all six handlers. |
| SAM validation described in the [deployment guide](DEPLOY_AWS_LAMBDA_WITH_SAM.md#3-validate-the-sam-template) | Template validity; no cloud enforcement evidence. |

Required regression coverage includes generic HTTP behavior without AWS metadata;
named-route and Function URL payload 2.0 compatibility; plain/base64 equivalence;
authentication/method/body precedence; ignored Query bodies; malformed/missing
bodies; the 4,096/4,097-byte Body boundary within larger envelopes; escaping,
whitespace, duplicate keys, Content-Type tolerance, and stable hashing; exact
path UUID extraction and ambiguous-header rejection; matching retries, conflict,
publication uncertainty, terminal Results, and cross-tenant warm-cache reads;
allocation/encoding failures, response lifetime, and recovery on later invocations.
Infrastructure coverage includes CORS/catch-all/Function URL absence and
representative valid access-log JSON when integration fields are unavailable.

Local checks establish application behavior and declared configuration. They do
not establish deployed route enforcement, effective invocation permissions,
absence of live public Function URLs, actual throttle enforcement, or CloudWatch
receipt/retention. Deployed acceptance requires separately authorized AWS checks
of these properties and representative PASETO/tenant cases. Throttle traffic
experiments must be bounded and cannot assert an exact best-effort rejection
threshold. Inspect cleanup configuration without treating live stack deletion
as an implied test. Record cloud evidence separately from local results.
