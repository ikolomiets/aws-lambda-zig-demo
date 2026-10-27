# 0007: Preserve the first valid Seat Reservation completion

Seat admission and completion are separate deliveries. A local rejection records
its admission outcome as a code-only Body and preserves the original input as
Context. Completion does not rerun admission: an `event_not_ready` rejection still
wins when its Event becomes ready before delivery. This keeps one Operation UUID's
observable outcome stable across delay and redelivery.

The Operation update guards UUID, tenant, exact name `SeatReservation`, `SUBMITTED`
state and absent Result. It does not compare the original input hash. A failed or
uncertain write requires authoritative readback; only a matching identity and valid
terminal seat Result establish a durable winner. That first Result remains immutable,
even when a later completion proposes a different valid outcome. Infrastructure
uncertainty remains retryable; diagnosed inconsistencies produce bounded ERROR
output and acknowledge without inventing a public Result.

Durable Event identities remain separate from disposable Operations, as described in
[ADR 0004](0004-seat-event-identities.md). Runtime creation completion uses a
transaction to guard the full saved Event configuration and creating state together
with the submitted, absent-Result Operation
identity. Ready/success and permanently failed/failure commit together. Account and
funding chains remain separate native phases, so incomplete or uncertain native
initialization stays creating. Stable saved identities permit complete-chain replay;
they do not make the two native phases atomic.

Transaction conflicts and uncertain responses require a coherent transactional pair
read. A matching terminal pair is the immutable winner, including when later valid
evidence proposes the opposite outcome. A matching creating/submitted pair remains
retryable. Contradictory states or identity/configuration mismatches are diagnosed
without mutation. Failed Events have no repair transition; a new creation Operation
provides a new Event. Separate writes cannot replace the transaction, and deletion
of a disposable Operation does not authorize reconstructing or repairing completion.

No durable per-Operation execution plan, outbox or reconciliation process is added.
A terminal Result does not establish exactly-once native effects or reverse another
attempt's effects; subsequent native execution must allow abandoned holds and retain
stable saved initialization identities. Recovery remains bounded by Operation retention.
The [seat reference](../SEAT_RESERVATION.md) owns the implemented wire and delivery contract.

Reserve submission generates a fresh pending transfer ID after whole-command
admission and carries that exact ID in flat Context. Complete singleton native
evidence establishes success; Context alone does not. Retries of submission may
create different holds, so one Operation can leave abandoned holds even when a
capacity rejection wins its immutable Result. Operation finalization does not
cancel those holds or choose which native attempt may execute.

Replaying a constructed native message retains every transfer field and ID.
The timeout begins at native creation and replay never renews it. Native cleanup
can lag the deadline, and delayed completion can persist success after the hold
has expired. Results therefore identify a successfully created hold without
promising remaining lifetime or synthesizing an expiry timestamp. Avoiding saved
plans and reservation ownership storage keeps this limitation explicit.

Confirmation generates a separate fresh posting ID and retains only the pending
reference in Context. Its full-post amount and explicit authorized debit, credit,
ledger and code bind native execution to the selected Event/class, including when
the pending transfer is already posted. Matching replay and already-posted outcomes
persist the same effective success naming the input reservation, without a quantity.
The first valid Operation Result still wins across competing confirmation attempts.
Fresh submission retries may choose new posting IDs; no durable plan is added.
