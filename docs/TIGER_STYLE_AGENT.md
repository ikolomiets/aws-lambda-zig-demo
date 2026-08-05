# Tiger Style for Agents

This is the concise operational profile of
[`TIGER_STYLE.md`](TIGER_STYLE.md). Read it before modifying Zig code. The full
guide remains the authoritative source for Tiger Style philosophy, rationale,
and examples.

Tiger Style is the preferred default, ordered by safety, performance, and
developer experience. Apply it to new and modified code when it fits the
existing architecture, behavior, and conventions. Do not make broad refactors,
compatibility changes, or unrelated edits solely to conform existing code. If
a material recommendation is unsuitable, keep the exception narrow and explain
why in the change summary.

## Safety and Control Flow

- Prefer simple, explicit control flow and a minimum of domain-appropriate
  abstractions. Do not introduce recursion.
- Put visible bounds on loops, queues, buffers, batches, retries, input sizes,
  and work performed per Lambda invocation. Assert the intentional exception
  for a loop that cannot terminate.
- Handle every expected operating failure with Zig errors. Do not use an
  assertion for invalid external input, unavailable services, allocation
  failure, or another condition the program is expected to encounter.
- Actively use assertions for programmer errors. Assert arguments, results,
  preconditions, postconditions, invariants, boundary assumptions, and
  relationships between compile-time constants.
- Assert both positive space and negative space: state what must be valid and
  what must be impossible. Place complementary checks on distinct boundaries
  when that materially improves fault detection.
- Split compound assertions so each failure identifies one violated property.
  Assertions must be side-effect-free. There is no required assertion count;
  use enough assertions to encode the actual safety model.
- Prefer positive conditions. Split complex boolean conditions and `else if`
  chains when doing so makes the cases independently verifiable.
- Keep branching and mutable state in the parent function where practical.
  Push loops and non-branching calculations into focused helpers, and keep leaf
  helpers pure when that produces a clearer design.
- Keep variables in the smallest useful scope. Avoid aliases and duplicated
  mutable state, and perform checks close to use.
- Pass dependencies, effects, and important library options explicitly. Avoid
  hidden global state and implicit defaults whose future changes could alter
  behavior.

## Types and Memory

- Use fixed-width integers for domain values, persisted data, wire formats,
  identifiers, counters with protocol limits, and timestamps. Use `usize` for
  indexes, slice lengths, allocator interfaces, and standard-library APIs where
  it is the natural type. Make conversions explicit and checked.
- Treat indexes, counts, and byte sizes as different concepts. Put units and
  qualifiers in names and use explicit division operations when rounding
  behavior matters.
- Dynamic allocation is allowed in this Lambda project. Pass allocators
  explicitly, bound allocation from external input, and make ownership and
  lifetime clear.
- Prefer caller-provided buffers, request-scoped arenas, or existing Lambda
  context resources when they are the appropriate owner. Pair acquisition with
  `defer` or `errdefer`, and avoid repeated allocation in hot loops.
- Pass a value larger than 16 bytes as `*const` when copying is not intended.
  Initialize large or immovable structures in place when pointer stability or
  stack usage matters.

## Performance

- Consider performance during design. Sketch network, disk, memory, and CPU
  costs, accounting for both latency and bandwidth and for frequency of use.
- Bound and batch work where it improves control or amortizes resource costs.
  Lambda remains event-driven; the goal is predictable work per invocation,
  not a TigerBeetle-style long-running scheduler.
- Separate control-plane decisions from data-plane work when the distinction
  makes safety or batching clearer.
- Keep hot loops explicit and isolated. Do not depend on speculative compiler
  optimization to remove avoidable work.

## Naming and Interfaces

- Use `snake_case` for functions, variables, and files. Prefer descriptive
  names, avoid unnecessary abbreviations, and capitalize acronyms correctly.
- Put units and qualifiers last, from most to least significant, such as
  `latency_ms_max`. Prefer nouns for state and components.
- Use an options struct when same-typed arguments could be confused. Pass
  callbacks last.
- Put important declarations near the top and use a consistent order within a
  file. Keep `comptime` small and purposeful.
- Explain why a decision exists, not merely what the code does. Write comments
  as clear sentences and describe non-obvious test goals and methodology.
- Existing pinned dependencies are permitted. Add a dependency only when the
  task needs it and after explicit approval; consider its security,
  performance, and maintenance costs.

## Mechanical Defaults

Use these as strong defaults for new and modified code. Do not restructure a
substantial existing area solely to satisfy a numeric limit.

- Keep functions at or below 70 lines.
- Keep lines at or below 100 columns.
- Use 4 spaces for indentation.
- Run `zig fmt` and the relevant repository validation commands.
- Use braces unless an `if` fits entirely on one line.

Consult the full [`TIGER_STYLE.md`](TIGER_STYLE.md) before architectural or
performance-sensitive work, new abstractions, memory-management or control-flow
changes, dedicated design reviews, or whenever this profile is ambiguous.
