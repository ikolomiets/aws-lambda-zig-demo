---
status: accepted
---

# Use one API Gateway entry point for Operations

The accepted design is one public AWS API Gateway HTTP API for Operation
submission and querying, with centralized routing, throttling, and access logs.
Direct public Lambda Function URL access is removed so that callers cannot bypass
the gateway's controls. There are no existing callers, so the design requires no
compatibility rollout or period with both public entry points available.

The API uses Lambda proxy payload format 2.0 and exposes `POST /operations` and
`GET /operations/{id}`, without a version prefix. HTTP API supplies the required
gateway features without adopting REST API features that this design does not
require. Intake and Query continue verifying PASETO themselves; the verified
subject remains the sole source of Operation Tenant. This preserves the existing
authentication boundary and avoids another Lambda and an authorization cache.
Requests with invalid credentials still invoke the matching handler before
receiving `401`.

The application owns a small `HttpRequest` / `HttpResponse` interface. Intake,
Query, and authentication use that interface without depending on API Gateway
event fields or Function URL request types. Lambda entry points own runtime
context and the AWS adapter. One adapter handles both HTTP API and Function URL
payload 2.0 event shapes and encodes responses using the existing pinned Lambda
dependency. This keeps the dependency unchanged while isolating transport details
from application behavior; it does not retain public Function URLs in deployment.

The request interface exposes method, path, headers, and deferred body access.
The response exposes status, headers, and body. Application routing extracts the
UUID from `/operations/{id}` without requiring gateway `pathParameters` or
`routeKey`. The adapter hides base64 handling, preserves ambiguous-header rejection,
and retains response data until serialization completes. Body decoding occurs only
after authentication and method checks; Query does not need to read a body.
This uses one shared interface and a concrete adapter, without an adapter registry
or a general transport framework.

Gateway base64 bodies are decoded before existing Operation validation. Plain and
base64 representations of the same request have the same application behavior;
after authentication and method checks, malformed base64 receives `400`.
Existing Content-Type tolerance is preserved.
The 4,096-byte bound continues to apply to the Operation Body's serialized JSON,
including escaping and internal whitespace. No new application limit is imposed
on the complete Operation envelope, and decoding does not normalize its JSON.

The existing SAM stack owns the API, which uses its AWS-generated HTTPS hostname
and the `$default` stage. Public routes have no stage prefix; separate deployments
use separate stacks. The default stage does not introduce a catch-all route.
The initial API targets non-browser callers with CORS disabled. A custom domain,
DNS management, and certificate management are outside this design's scope.

One `OperationsApiUrl` stack output replaces the two Function URL outputs.
Repository tools construct the submission and query routes from that API origin.
Deployment probes, Events tooling, seat scenarios, tests, and documentation change
together, without compatibility aliases for the former outputs.

Only the two named routes invoke handlers. Requests that reach a handler retain
the existing handler statuses and bodies, including successful `200` responses. Unmatched
paths and methods receive gateway `404` responses without invoking a handler.
Gateway rejections, including throttling, retain their native response formats;
the API does not promise one error-body format across gateway and handler errors.
This avoids a catch-all Lambda whose sole purpose is normalizing rejections.

Throttles are configurable per route, initially 10 requests per second with burst
capacity 20 for submission and 50 requests per second with burst capacity 100 for
querying. These demo defaults allow more polling than submission. All callers
share each route's allowance; the limits are best-effort targets, not per-tenant
quotas or a guarantee of downstream capacity. Clients back off after `429`.

The stack owns a structured JSON access-log group with seven-day retention and
deletes it with the stack. Access logs contain request identifiers, route template,
status, and timing. Credentials, request and response bodies, query strings, and
client IP addresses are excluded. This policy applies to gateway access logs;
it does not change existing Lambda application-log settings.

This changes the public HTTP boundary while preserving asynchronous execution,
UUID-based idempotency, Operation Tenant ownership, and polling for Completion.
The existing [Operation identity contract](0001-operation-json-hash-contract.md),
[lifecycle](0002-two-state-operation-state.md), and
[processor transport](0003-minimal-processor-messages.md) remain authoritative.

Implementation validation must test handler behavior through the application-owned
HTTP interface, with separate AWS event compatibility tests for both supported
event shapes. Required coverage includes named routes, equivalent plain/base64
requests, authentication and method precedence, Operation Body limits within larger
envelopes, tenant isolation,
idempotency, and warm query caching. Deployment-helper tests and SAM validation
must cover routes, permissions, outputs, throttles, and logging configuration;
runtime tests must exercise the Lambda entry points. The [local-check guide](../agents/local-checks.md)
owns validation commands and their evidence limits.

The complete design is accepted. Implementation and the required validation are
pending.
