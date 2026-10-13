# Local Markdown issue tracker

This repository uses local Markdown issues to track project-wide work, including features,
bugs, research, documentation, and deployment changes. Apply these conventions to any
component or cross-cutting effort. No hosted tracker has been configured.

## Layout

Each effort lives under `.scratch/<effort>/`. Choose a descriptive name for its scope.
Its `issues/` directory contains one file per issue, including the map. Each issue has YAML front matter with `id`, `title`, `status`
(`open` or `closed`), `labels`, `parent`, `assignee`, `mode`, and numeric `order`.
Keep front-matter values on one line; labels use an inline list. Use `null` for an absent parent
or assignee. IDs are immutable and unique across local efforts. IDs, parent IDs and
assignees use letters, digits, dots, underscores or hyphens, starting with a letter
or digit. Modes are `AFK` or `HITL`; order is an integer. Scalars and label entries
may be bare, single-quoted (double embedded apostrophes), or double-quoted with JSON
string escapes. Multiline values, YAML aliases/tags and inline comments are outside
this format. Empty inline label lists are valid.
File names contain an ordering prefix and a readable name. Human-facing references always
link the issue title.

For incoming issue triage, use the [triage label mapping](triage-labels.md).
Triage roles live in `labels`; `status` continues to record only `open` or `closed`.

`comments/<issue-id>/` stores separate dated comment files. Research assets live under
`docs/research/` and are linked from resolution comments. Do not store answers in the
question body or duplicate them in the map.

## Tracking operations

- **Create a map:** create an issue labelled `wayfinder:map` with no parent. Use the
  Destination, Notes, Decisions so far, Not yet specified, and Out of scope sections.
- **Create children:** create an issue labelled `wayfinder:research`, `wayfinder:prototype`,
  `wayfinder:grilling`, or `wayfinder:task`; set `parent` to the map ID.
- **Wire blocking in a second pass:** this tracker has no native dependency UI. Its fallback
  is each child's `## Blocked by` section: one Markdown link to a blocking issue per line.
  Links may have a `- ` prefix and a trailing period. An empty section is written as
  `None.`. These links are the sole source of blocking edges.
- **Query the frontier:** select open children whose assignee is `null` and whose blockers
  are all closed, ordered by `order`, then ID. The command below reads the current files;
  do not maintain an open-ticket list in the map.
- **Claim first:** set `assignee` to the developer driving the effort before ticket work.
  A delegated agent records its identity in a separate claim comment. Re-read the issue
  before changing it and do not take an already assigned ticket.
- **Resolve:** add a dated resolution comment under `comments/<issue-id>/`, with the
  answer or a link to its research asset and relevant evidence. For implementation,
  review every acceptance criterion, check satisfied criteria, and use `complete`
  below. Then append a one-line gist linking the issue title to the map's Decisions
  so far. Research and decision resolutions retain their existing answer convention.
- **Release a claim:** set `assignee` back to `null` if work stops before resolution.
- **Exclude:** label mis-scoped work `wontfix`, record a dated exclusion resolution,
  close it, and link it only from the map's Out of scope section. Exclusion records use
  `Disposition: excluded` and a nonempty `## Exclusion reason` section. Historical
  resolutions beginning with `# Exclusion` and followed by a prose reason also count.
- **Concurrent edits:** separate tickets can be worked independently. Serialize edits to the
  map index, re-read before patching, and use patches that preserve other sessions' entries.
  Claims are file-based; coordinate if two sessions attempt to claim at the same time.

## Command usage

[tracker.py](../../tracker.py) uses Python 3.9 or newer and its standard library.
Run these commands from the repository root:

```sh
python3 tracker.py validate
python3 tracker.py frontier '<effort>' '<parent-id>'
python3 tracker.py complete '<effort>' '<issue-id>' --resolution 'YYYY-MM-DD-resolution.md'
```

`validate` discovers `.scratch/*/issues/*.md`, including ignored local efforts,
without a registry. A missing tracker or an empty effort reports `Validated 0 issues.`
`frontier` selects children of the named map or specification, ordering numeric
`order` then ID. It prints titles and paths relative to the tracker root, and prints
nothing when no work is ready. Maps use `wayfinder:map`; specifications use
`wayfinder:spec` or the existing `## Problem Statement` and `## Solution` headings.
Both may omit `## Blocked by`. Closed issues may retain assignees and labels;
additional labels and equal orders are valid.

Both read-only commands leave issue/comment bytes and modification times unchanged.
All commands validate discovered efforts first. Malformed/missing metadata,
duplicate IDs, missing or cross-effort parents/blockers, malformed blocking sections,
parent or blocking cycles, and successfully closed work with open blockers fail
with issue-specific diagnostics. Blocking links target issue files in the same
effort's `issues/` directory; fragments, queries and external URLs are invalid.
Closed `wontfix` issues may retain open blockers only with an exclusion resolution.
Validation preserves historical resolutions and imposes no new checkbox or review
fields on previously closed work.

`complete` requires an open, claimed issue, closed blockers and a nonempty
`## Acceptance criteria` checklist whose items are all checked. Markdown `-`, `*`,
`+` and numbered lists are supported, with `[x]` or `[X]` check marks.
Prepare the dated resolution in that issue's comment directory before running it:

```markdown
# Resolution — Issue title

Disposition: completed
Reviewed by: <reviewer identity>

## Acceptance evidence

- Record the reviewed disposition and evidence for each criterion, including
  relevant source/test links, validation results and remaining limitations.
```

The resolution filename contains a real calendar date and ends in `-resolution.md`
(an extra descriptive component after the date is allowed). The command requires
exactly one completed disposition, exactly one named reviewer and a nonempty
acceptance-evidence section. Review fields and section headings must be outside
fenced examples and HTML comments. It checks structural readiness and the recorded review requirements;
the reviewer decides semantic acceptance. Boxes, commits and evidence text alone
do not prove the implementation. `complete` changes only `status` to `closed`,
preserving the issue's other bytes, line endings, permissions, assignee and labels.
It leaves comments and the map untouched; append the decision gist after success.
Any failed check leaves files unchanged. `wontfix` uses the exclusion workflow
above instead of successful completion.

All commands accept `--root '<tracker-root>'` before the operation for temporary
trees or another checkout. Success exits 0, tracker failures exit 1, and invalid
command arguments exit 2. No command contacts services or examines Git/code to
infer acceptance. Test the command with `python3 tests/tracker_test.py` or
`zig build test-tracker`; the same temporary-tree tests are in `zig build test`.

Research worktrees may retain uncommitted findings on a `research/<name>` branch; record the
branch and worktree in the ticket's comments and keep the reviewable asset in `docs/research/`.
Repository instructions prohibit creating commits without the user's explicit request.
