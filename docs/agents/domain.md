# Domain documentation

This repository has one context: the root `GLOSSARY.md` defines its domain
vocabulary, and `docs/adr/` records lasting architectural decisions.

Before exploring engineering behavior, read `GLOSSARY.md` and the ADRs relevant
to the area being changed. Use the glossary's canonical terms in issues,
specifications, hypotheses, tests, and documentation. When a proposal contradicts
an ADR, identify the conflict explicitly before changing the contract.

Capture resolved terms in `GLOSSARY.md` using `domain-modeling`. Keep behavior and
implementation details in their reference documents; use ADRs for decisions with
meaningful trade-offs that are costly to reverse and need their rationale preserved.

The source pointers in `AGENTS.md` identify the implementation and reference
documents to consult for each area.

## Bounded exploration

1. Begin each batch with one concrete question and the relevant `AGENTS.md`
   source pointer. Discover filenames with `rg --files`, headings with
   `rg -n '^#{1,4} '`, and declarations or callers with a focused symbol search.
2. Select the ranges that answer the question, including nearby callers when
   they determine behavior and the relevant failure paths. Start with about
   80–150 source lines per excerpt, adjusted for line length and content density.
3. Aim for about 3,000 tokens of combined exploration output per batch, leaving
   headroom within the actual enclosing tool-call and child-call output limits.
   Parallel reads share that aggregate budget: count discovery output and every
   read toward the batch total. Batch independent reads when they answer the
   same question and their combined output fits. These defaults guide selection
   while preserving necessary context.
4. State the purpose and estimate the output before a full-file read. Read
   mandatory long references completely in sequential, bounded chunks; apply
   the same approach to required large collections, preserving domain and
   safety material.
5. Match requested excerpts to the output limit by narrowing files, patterns
   or ranges before lowering output limits. A lower cap alone leaves a broad
   request subject to truncation.
6. Discover tools by returning matching names and short descriptions first,
   then request documentation only for the selected tools.
7. Recover any omitted relevant ranges before drawing conclusions, including
   when a tool reports truncation. Record the warning, recovered ranges and
   answered question briefly in working context; reuse unchanged evidence for
   the same question. Read sources again when they change or a new question
   needs more context, using working context rather than a separately maintained
   inventory of files read.
8. For lengthy command output, retain the full local log outside version
   control. Return the phase, exit status, relevant diagnostic excerpt and log
   path so the evidence remains available after the tool output ends.
9. Stop exploration when the relevant current contract, implementation symbols
   and validation path answer the question. Dated research supplies rationale
   and forwards to current authority.
