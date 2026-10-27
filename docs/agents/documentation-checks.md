# Documentation checks

[check_docs.py](../../check_docs.py) uses Python 3.9 or newer and the standard library.
From the repository root, run:

```sh
python3 check_docs.py
python3 check_docs.py README.md docs/TIGER_BEETLE_PROCESSOR.md
python3 tests/documentation_check_test.py
zig build test-docs
```

The default scan covers root Markdown files and `docs/**/*.md`, including research.
Explicit file arguments select a smaller scan; `--root` selects a fixture or another
checkout. Local tracker documents are outside the default scan; they can be selected
explicitly. The command reads files, returns 0 for success or 1 for check/setup
failures, and prints the source file, line, and broken destination or command name.
Invalid command-line arguments return 2. It does not execute examples or contact services.
The temporary-repository tests also run in `zig build test`; the documentation scan
remains independently usable and runs in the [complete offline checks](local-checks.md#complete-offline-checks).

## Links and anchors

The check covers inline links and images, full/collapsed reference links, and shortcut
references with definitions. Relative destinations resolve from the source document.
Targets must exist inside the repository. Markdown headings use lowercase anchors,
punctuation removal, hyphens for spaces, and duplicate-heading suffixes; ATX and Setext
headings and explicit HTML `id`/`name` anchors are supported. Source-file `#L1` and
`#L1-L2` anchors must fit the file's line count. URL-encoded destinations and angle-bracket
destinations containing spaces are supported. Fenced examples, inline code, and HTML
comments do not create links. Nested link labels and multiline destinations are
checked with their opening source line. Remote URLs are outside the check's scope.

This is a checker for ordinary repository Markdown, not a complete Markdown renderer.
It does not interpret MDX, generated navigation, arbitrary HTML links, or custom renderer
extensions. Keep checked links in the supported forms; review unusual rendering manually.

Absolute paths, `file:` links, home-relative paths, and relative paths outside the
repository fail as nonportable destinations. Preserved archival documents can be named in
the optional `docs/agents/documentation-archives.json` registry, with a reason and SHA-256
of their exact bytes. A missing registry is equivalent to an empty one. For registered
documents only, the check reports the count of absolute
machine-local evidence links and treats command mentions as historical. Relative links
are still checked. A changed archive fails its checksum check; the registry does not
exempt ordinary research or current reference documentation. Archival documents can be
optional local research: when absent, they are outside the scan and no checksum is read.
Ordinary links to absent archives still fail.

## Command names

Current commands are read from inline code and shell fences labelled `sh`, `bash`,
`shell`, or `console`. Shell continuations, environment assignments, and command
separators are supported. Entry-point names are checked for direct commands such as `./events.sh`,
`bash`/`sh` script operands, and `python3`/`python` script operands, relative to the
repository root. Generated binaries such as `zig-out/bin/events` are checked against literal
`addExecutable` names in [build.zig](../../build.zig), so a prior build is unnecessary.
`zig build` target operands are checked against literal `step` declarations in that
file, plus Zig's built-in install/uninstall steps. Declaration comments do not add names.
There is no separate maintained list of project targets or executable names.

The checker skips option tokens, values for the common Zig build path/report options,
and arguments following `--`. It does not validate options, environment expansion,
subcommands, external tools, computed build declarations, command substitutions, shell
functions, generated scripts, or a changed shell working directory. Keep runnable
repository examples rooted at the checkout. Full shell syntax and integration behavior
belong to their existing checks and manual review.

Label planning and historical examples visibly in prose. For a shell fence, use `sh planning`
or `sh historical` (also supported with the other shell labels). For a section containing
inline commands, put `<!-- doc-check: commands=planning -->` or
`<!-- doc-check: commands=historical -->` on its own line and restore
`<!-- doc-check: commands=current -->` at the end. These directives affect command checking
only; ordinary links still fail when broken. Historical examples from another checkout
must name that checkout in their explanation.

## Manual review

When examples change, review option names and subcommands against the actual CLI or
script, and integration prerequisites against the current
[deployment guide](../DEPLOY_AWS_LAMBDA_WITH_SAM.md). Check table bindings, credentials,
toolchain/package provisioning, and live-replica or cloud requirements before presenting
an example as runnable. Passing this check establishes names and destinations only.

When support becomes executable, reconcile deferred or support-status claims in
the owning reference and linked evidence index with the implemented contract and
its evidence limits. Historical reports retain their original revision, results
and limitations; update current references rather than rewriting those reports.

Review Processor Message semantics against the
[processor contract](../TIGER_BEETLE_PROCESSOR.md),
[message ADR](../adr/0003-minimal-processor-messages.md), and
[glossary](../../GLOSSARY.md#operation-execution). Existing `test-processor-message` and
`test-tigerbeetle-processor` codec/invocation tests provide implementation evidence.
This command does not mark, extract, generate, or validate message examples or schemas.
