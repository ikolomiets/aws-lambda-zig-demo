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
