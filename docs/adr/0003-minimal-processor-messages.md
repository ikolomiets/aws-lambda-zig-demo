# Separate processor messages from persisted Operations

Processors exchange one `{operation_id, tenant, body, context, result_queue?}` envelope per SQS
message. The Operation UUID correlates the work; trusted tenant identifies the authenticated
requester. Context is an opaque JSON value owned by participating domain processors. Explicit
null means no Context; omission is invalid. Same-type outputs preserve tenant and Context even
when Body changes, including diagnostics. Native execution interprets neither as resource
authorization. Name, lifecycle, timestamps and original-input hash remain at intake and persistence,
so execution is independent of an Operation snapshot and supports another processor's output.

Intake derives tenant only from the verified PASETO subject and emits null Context. Tenant retains
its 1–64-byte UTF-8 contract. Unknown fields, duplicate decoded keys and invalid metadata are
rejected. Public callers cannot supply tenant, Context or routing. Public Results acquire no
Processor Message fields.

Incoming `result_queue` overrides the processor's default result destination. Each processor
chooses its outgoing route independently; TigerBeetle currently omits it. Public intake exposes
no routing metadata. Queue producers and IAM remain the trusted internal boundary; the absence of
hash verification in a processor is deliberate, not an authentication mechanism being removed.

Native execution emits its result details directly as `body`. TigerBeetleCompletionProcessor
interprets those details and creates the existing tagged persisted Result. The executor retains
native chain classification needed for execution control, including transfer eligibility, but
no longer emits a terminal success/failure discriminator.

Intake Body remains limited to 4,096 bytes. Internal Bodies permit 98,304 compact JSON bytes so
results can become inputs; Context permits 4,096 compact JSON bytes. Decoded routes permit 2,048
bytes. The compact shared envelope is bounded at 115,328 bytes, with the same pre-parse raw-input
cap. Serializer checks include escaping; SQS request and Lambda event wrapping have separate
transport costs. TigerBeetle admits at most 64 commands. The complete persisted Result keeps its
98,304-byte bound; executor admission reserves room for the wrapper the final processor adds.

Each Operation output occupies one message, with at most ten serial SQS sends per executor
invocation and one conditional write per final invocation. Publication follows source order,
skips unfinished work, and stops at the first failed or uncertain send. Only successfully published
sources acknowledge, including when destinations differ. This preserves retry eligibility without
a durable execution journal or publication outbox.

The codec accepts only the current envelope. Operational rollout instructions belong in the
[deployment guide](../DEPLOY_AWS_LAMBDA_WITH_SAM.md#processor-message-rollout).
