---
status: accepted
---

# Integrate external identity providers through source modules

Each supported identity provider has a source module in the Operations framework.
GitHub is the first provider. Its module authenticates a person or agent directly
with GitHub using OAuth and resolves the Operation Tenant from the authenticated
identity. This keeps the provider's sign-in protocol and tenant rule together and
avoids introducing a separate identity broker.

The common contract is a verified Operation Tenant ready for PASETO issuance.
A future OIDC module can verify an ID token and apply its own tenant rule. The
issuer does not need to know whether a module verified a signed claim locally
or obtained the account identity from its provider's API.

## GitHub identity and sign-in

One GitHub account corresponds to one Operation Tenant. Its tenant is
`github:<id>`, where `<id>` is GitHub's durable numeric account ID in decimal.
A change of login therefore preserves ownership of existing Operations. Members
of the same GitHub organization have separate tenants. The `github:<numeric-id>`
namespace is reserved for those accounts. Since manually issued subjects can
already have this form, the operator resolves any existing use of such a subject
for an unrelated tenant before enabling sign-in.

When a deployment enables GitHub, any GitHub account may sign in and submit
Operations under its tenant. An HTTP client can begin sign-in knowing the
Operations API origin. Headless clients use device approval through Operations.
A web app can instead redirect the person to GitHub and receive them back after
approval without asking them to copy a device code. Both flows require only the
public account ID for tenant resolution.

GitHub redirects to the Operations callback. Operations checks its own OAuth
state and uses S256 PKCE when it redeems GitHub's authorization code. The
browser app has a separate S256 challenge and verifier. Operations redirects
to the app's exactly registered HTTPS callback with a short-lived, single-use
Operations code. The app redeems it with its verifier to receive credentials
in the HTTPS response body.

Pending sign-ins live in DynamoDB so a later callback, poll or redemption
can reach a different Lambda instance. Operations enforces expiry on access
and uses a conditional write to consume each successful grant once.

The host command `paseto login github` shows the device code and browser
instructions on standard error and writes the PASETO alone to standard output.
It uses the same Operations sign-in endpoints as other headless HTTP clients.
An agent that already holds a GitHub token for this OAuth App can submit it
directly to obtain a PASETO.

## Credential exchange and lifetime

GitHub owns the user's GitHub login session and the lifecycle of its OAuth
credentials. Operations uses GitHub to authenticate the caller and issues
PASETOs for the Operations API. Checking whether a GitHub access token is
still valid is a read-only check. GitHub token refresh, GitHub grant
revocation and signing the user out of GitHub are outside this contract.

The client presents its GitHub user access token to `POST /auth/github/exchange`
on the Operations API. A dedicated exchange Lambda uses the deployment's OAuth
App credentials to [check the token with GitHub](https://docs.github.com/en/rest/apps/oauth-applications#check-a-token).
It requires a token issued to that app and uses the returned `user.id` for
tenant resolution.

The framework issues a PASETO with the resolved Operation Tenant as its `sub`.
Intake and Query continue to use that subject for [Operation identity and
ownership](0001-operation-json-hash-contract.md), so adding a provider does not
require either handler to interpret its credentials.

A successful sign-in or direct exchange issues one PASETO with a default
lifetime of eight hours (28,800 seconds) from issuance. Its signed expiration
is fixed. The framework does not support PASETO renewal or issue a refresh
credential. To obtain another PASETO, the caller completes a new sign-in or
presents an eligible GitHub token for a fresh, independently verified exchange.

Operations discards the GitHub access token after resolving the tenant. Revoking
that token prevents future exchanges using it. An issued PASETO continues to
authorize Operation requests until its signed expiration, when Intake and Query
reject it. Their verification requires no GitHub call or server-side session.

Browser apps hold the PASETO in memory. Only temporary PKCE and correlation
data survive the redirect in tab-scoped storage. The app clears them on return.
Signing out locally discards the PASETO. A reload after sign-in requires a fresh
sign-in.

## Deployment boundary

Browser-only applications can sign in and submit and query Operations directly
from origins explicitly enabled by the deployment. This extends the initial
non-browser scope in the [gateway decision](0008-api-gateway-operation-ingress.md).
CORS enablement grants a browser origin access to responses. Operation
authorization still requires the caller's PASETO.

GitHub sign-in is off by default. Enabling it opens the deployment's configured
Operations to any GitHub account that authorizes its OAuth App. Operation Tenant
protects reads of an Operation. The generic TigerBeetle processor can execute
lookups and transfers against known cluster-wide resource IDs, subject to its
admission checks and the ledger rules. The deployment guide must explain this
consequence at enablement. See the [processor contract](../TIGER_BEETLE_PROCESSOR.md#framework-boundary).

Deployment configuration supplies the public GitHub client ID and references
to the GitHub client secret and PASETO signing key in AWS Secrets Manager. Among
the Lambdas, only the exchange function has permission to retrieve those secrets.
The signing key must match the Ed25519 public key configured for Intake and Query.
