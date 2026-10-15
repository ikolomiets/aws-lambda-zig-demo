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
[ADR 0004](0004-seat-event-identities.md). The shared Event and Operation update
builders compose atomically in the isolated [SDK transaction probe](../SEAT_TRANSACTIONS.md).
The probe establishes the persistence seam; runtime native creation finalization is
a separate implementation slice. The accepted creation contract requires Event
readiness and the creation Result to commit together. Separate writes cannot replace
that transaction.

No durable per-Operation execution plan, outbox or reconciliation process is added.
A terminal Result does not establish exactly-once native effects or reverse another
attempt's effects; subsequent native execution must allow abandoned holds and retain
stable saved initialization identities. Recovery remains bounded by Operation retention.
The [seat reference](../SEAT_RESERVATION.md) owns the implemented wire and delivery contract.
