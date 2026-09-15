# Separate processor messages from persisted Operations

Processors exchange one `{operation_id, body, result_queue?}` envelope per SQS message. The
Operation's tenant, name, lifecycle, timestamps and original-input hash remain at intake and
persistence. Carrying them through execution coupled processors to an input snapshot that cannot
represent another processor's output.

Incoming `result_queue` overrides the processor's default result destination. Each processor
chooses its outgoing route independently; TigerBeetle currently omits it. Public intake exposes
no routing metadata. Queue producers and IAM remain the trusted internal boundary; the absence of
hash verification in a processor is deliberate, not an authentication mechanism being removed.

Native execution emits its result details directly as `body`. TigerBeetleCompletionProcessor
interprets those details and creates the existing tagged persisted Result. The executor retains
native chain classification needed for execution control, including transfer eligibility, but
no longer emits a terminal success/failure discriminator.

Intake input remains limited to 4 KiB. Internal Bodies permit 96 KiB so results can become inputs.
TigerBeetle still admits at most 64 commands. The persisted Result envelope keeps its 96 KiB bound;
executor admission reserves room for the wrapper the final processor adds.

One message per operation replaces aggregation. This increases SQS sends to at most ten per
executor invocation and completion invocations to one per operation, while reducing each final
invocation to one conditional write. Serial publication preserves successful acknowledgements
when a later send fails, including when destinations differ.

This is a coordinated wire cutover with no dual parser. Drain old messages, including delayed or
in-flight retries and replayable dead-letter messages, before replacing producers and consumers.
Stored Operations and hashes require no migration. Rename the completion function, role, mapping,
parameters, outputs, executable and package to TigerBeetle-specific names; existing stacks require
a reviewed CloudFormation change set for those replacements. No cloud deployment is part of this change.
