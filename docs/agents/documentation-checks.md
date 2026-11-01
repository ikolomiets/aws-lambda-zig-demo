# Documentation review

Review documentation changes against the current repository and its owning references.

## Links and anchors

Use repository-relative links for current documentation. Resolve each destination
from its source document and verify that the file and heading or source-line anchor
exist. Check external links when they change. Links to optional local research
require an available destination when presented as current references.

## Command names

Check entry points, executable names, and Zig build targets against the scripts and
[build.zig](../../build.zig). Review command options against the actual CLI or script.
Keep runnable repository examples rooted at the checkout. Label planning and historical
examples visibly in prose, and identify the source checkout for historical commands.

## Manual review

When examples change, review option names and subcommands against the actual CLI or
script, and integration prerequisites against the current
[deployment guide](../DEPLOY_AWS_LAMBDA_WITH_SAM.md). Check table bindings, credentials,
toolchain/package provisioning, and live-replica or cloud requirements before presenting
an example as runnable.

When support becomes executable, reconcile deferred or support-status claims in
the owning reference and linked evidence index with the implemented contract and
its evidence limits. Historical reports retain their original revision, results
and limitations; update current references rather than rewriting those reports.

Review Processor Message semantics against the
[processor contract](../TIGER_BEETLE_PROCESSOR.md),
[message ADR](../adr/0003-minimal-processor-messages.md), and
[glossary](../../GLOSSARY.md#operation-execution). Existing `test-processor-message` and
`test-tigerbeetle-processor` codec/invocation tests provide implementation evidence.
