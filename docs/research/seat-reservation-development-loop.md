# Seat reservation development: code-only Lambda updates

Verified on 2026-09-27 against official AWS documentation and the locally installed
AWS SAM CLI 1.166.2 source. This is planning evidence, not an implemented helper.
No cloud APIs, deployments, builds, or package updates were run.

## Fit for this repository

The existing [template](../../template.yaml) points `CodeUri` at four prebuilt ZIPs
and uses `provided.al2023`, ARM64 and `bootstrap`.
[deploy.sh](../../deploy.sh) builds with Zig and packages `bootstrap` at each ZIP
root before deployment. Both update routes below can retain this packaging model.
The proposed seat functions first need a normal infrastructure deployment that
creates their queues, tables, permissions, environment and event mappings.

| Choice | Selection and behavior | Fit and constraints |
| --- | --- | --- |
| `sam sync --code --resource-id <logical-id>` | Uses stack logical resource IDs; repeat `--resource-id` for several functions. Uses service APIs rather than a CloudFormation deployment. | Convenient template-based selection; supports the existing prebuilt ZIPs in installed SAM. Requires the deployed stack/resource mapping and appropriate service permissions. |
| `aws lambda update-function-code --function-name <physical-name> --zip-file fileb://<archive>` | Updates one existing physical function. `--revision-id` guards against a concurrent change; omit `--publish` for the ordinary unpublished development target. | Smallest mechanism for a helper that explicitly uploads selected Zig packages and verifies each result. Resolve physical names from the selected stack rather than guessing. |

Sources: [SAM sync options](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-cli-command-reference-sam-sync.html),
[Lambda code update](https://docs.aws.amazon.com/cli/latest/reference/lambda/update-function-code.html).

The prebuilt-ZIP detail is verified in the installed first-party SAM source:
`samcli/lib/providers/provider.py` recognizes a `.zip` CodeUri as `PreZipped`;
`samcli/lib/sync/sync_flow_factory.py` selects
`ZipFunctionSyncFlowSkipBuildZipFile`; its implementation copies and uploads the
existing archive without building Zig or repackaging its contents. Thus this
installed version does not require adding `SkipBuild` metadata for these ZIP
paths. AWS also documents external builds and prebuilt ZIP CodeUri with
`SkipBuild: True` for the general build workflow.
Sources: [external-build documentation](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-using-build.html),
[SAM source tree](https://github.com/aws/aws-sam-cli/tree/v1.166.2/samcli/lib).
Local source inspected under
`/opt/homebrew/Cellar/aws-sam-cli/1.166.2/libexec/lib/python3.14/site-packages/`;
this is implementation evidence for that version, not a cloud smoke test.

## Infrastructure boundary and reconciliation

Use explicit `--code` for a code-only SAM operation. Installed
`samcli/commands/sync/command.py` dispatches it to code sync and disables
infrastructure sync even in watch mode. General `--skip-deploy-sync` is different:
AWS documents template comparison and circumstances that still cause deployment.
Ordinary `sam sync --watch` can update infrastructure and therefore is not a
replacement for this effort's guarded normal deployment path. AWS recommends
sync for development stacks. Source:
[SAM sync workflow](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/using-sam-cli-sync.html).

Neither selected code-only route installs missing resources or applies the seat
design's IAM, environment, runtime, memory, timeout, networking or queue/table
changes. Lambda separates code updates from configuration updates. Keep such
changes on the full, inspected deployment path. This is a repository workflow
recommendation derived from the API boundary, not a new AWS restriction.
Source: [Lambda update states and operations](https://docs.aws.amazon.com/lambda/latest/dg/functions-states.html).

Service-API code updates leave CloudFormation's recorded code artifact unchanged.
Reconcile accepted code through a later guarded full deployment with the intended
packaged artifacts, and verify the resulting function hashes. Do not treat an
empty change set or an `IN_SYNC` drift report as proof of code equality: AWS
explicitly excludes Lambda source code from CloudFormation drift detection.
The reconciliation procedure is an implementation recommendation.
Sources: [SAM sync options](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-cli-command-reference-sam-sync.html),
[CloudFormation drift limits](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html).

## Completion evidence and concurrent changes

For a direct-upload helper, the recommended per-function sequence is:

1. Resolve the selected stack's physical function, read its configuration/revision,
   and verify the expected ZIP/runtime/architecture target. Build and validate the
   selected archive locally; calculate the exact archive's SHA-256.
2. Upload with the previously read `--revision-id`. Capture the returned revision,
   version and package hash. This avoids blindly overwriting a concurrent update.
3. Run `aws lambda wait function-updated-v2`, then read back and require
   `State=Active`, `LastUpdateStatus=Successful`, the intended package hash, and
   the expected revision/version. Do not interpret `Active` alone as completion:
   the previous code remains callable while an update is in progress or fails.

Sources: [code-update revision guard and outputs](https://docs.aws.amazon.com/cli/latest/reference/lambda/update-function-code.html),
[function-updated-v2 waiter](https://docs.aws.amazon.com/cli/latest/reference/lambda/wait/function-updated-v2.html),
[GetFunction fields](https://docs.aws.amazon.com/cli/latest/reference/lambda/get-function.html),
[function update states](https://docs.aws.amazon.com/lambda/latest/dg/functions-states.html).

Installed SAM's `FunctionSyncFlow.update_function_with_lock` already waits for
the update; its ZIP sync also compares package hashes before uploading. The
observed ZIP call does not supply `RevisionId`, so it is not the same concurrency
guard as the proposed direct helper. Either workflow benefits from explicit
post-update artifact verification. Source:
[SAM sync implementation](https://github.com/aws/aws-sam-cli/tree/v1.166.2/samcli/lib/sync/flows).

Published versions are immutable, and aliases can continue pointing at a previous
version. Updating the unpublished function does not by itself establish that a
qualified integration runs new code. The current template uses unqualified
functions; preserve that baseline unless version/alias routing is separately
designed. Source:
[Lambda versions](https://docs.aws.amazon.com/lambda/latest/dg/configuration-versions.html).

Multiple function updates are not one transaction: the Lambda API updates one
function per request. A helper must report successful, failed and unattempted
targets separately and stop claiming overall success after partial updates.
This is an inference from the per-function API. Establish the coordinated new
envelope/infrastructure baseline through full deployment before using this loop
for compatible code iterations; rapid upload is not an atomic protocol cutover.
Source: [Lambda code-update API](https://docs.aws.amazon.com/lambda/latest/api/API_UpdateFunctionCode.html).

Recommendation: a narrowly scoped direct-upload development helper offers the
clearest revision and artifact verification for this repository. SAM code sync
is a viable alternative with less custom stack-resource selection. Both require
explicit deployment authorization when run; this note authorizes neither. The
accepted integration contract requires executing the exact inspected change set
for deployments. A code-only development path is an explicit exception to that
contract and requires a new user decision; it is not implicitly authorized by
this research. Neither route has a verified end-to-end timing guarantee here.
