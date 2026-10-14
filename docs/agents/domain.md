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

1. Start with the relevant `AGENTS.md` source pointer. Discover filenames with
   `rg --files`, headings with `rg -n '^#{1,4} '`, and declarations or callers
   with a focused symbol search before selecting excerpts.
2. Budget the combined output of each read batch at about 6,000 tokens, including
   parallel reads. Select heading ranges or symbol context that answer the
   current question, leaving room for discovery output in the same batch.
3. State the purpose of a full-file read before making it. Estimate its output
   first; split a large file or collection into bounded batches when needed.
4. If output truncates, narrow the files, pattern, or line range and read the
   missing relevant material again. Base conclusions on the recovered excerpts;
   an output cap alone does not establish that the required material was read.
5. Reuse material already read. Read it again when it changes or an unresolved
   question requires more context. Stop exploration when the relevant current
   contract, implementation symbols, and validation path answer the question;
   dated research supplies rationale and forwards to current authority.
