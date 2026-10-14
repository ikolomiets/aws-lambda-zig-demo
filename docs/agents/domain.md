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
   they determine behavior. Start with about 80–150 source lines per excerpt,
   adjusted for line length and content density. Use discovery searches to
   locate symbols before selecting source excerpts.
3. Aim for about 3,000 tokens of combined exploration output per batch, leaving
   margin below the existing budget of about 6,000 tokens. Batch independent
   reads when they answer the same question and their combined output fits;
   count discovery output and all parallel reads toward the whole batch.
   These defaults guide selection while preserving necessary context.
4. State the purpose and estimate the output before a full-file read. Read
   mandatory long references and large collections in sequential, bounded
   chunks, preserving required domain and safety material.
5. Match requested excerpts to the output limit by narrowing files, patterns
   or ranges. Lowering the output cap alone leaves the request too broad and
   causes truncation.
6. If output truncates, recover the missing relevant range immediately before
   drawing a conclusion. Record the answered question briefly in working
   context; reuse unchanged excerpts for the same question. Read sources again
   when they change or a new question needs more context, using working context
   rather than a separately maintained inventory of files read.
7. Stop exploration when the relevant current contract, implementation symbols
   and validation path answer the question. Dated research supplies rationale
   and forwards to current authority.
