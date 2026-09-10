# Local Markdown issue tracker

This repository uses local Markdown issues to track project-wide work, including features,
bugs, research, documentation, and deployment changes. Apply these conventions to any
component or cross-cutting effort. No hosted tracker has been configured.

## Layout

Each effort lives under `.scratch/<effort>/`. Choose a descriptive name for its scope.
Its `issues/` directory contains one file per issue, including the map. Each issue has YAML front matter with `id`, `title`, `status`
(`open` or `closed`), `labels`, `parent`, `assignee`, `mode`, and numeric `order`.
Keep front-matter values on one line; labels use an inline list. Use `null` for an absent parent
or assignee. IDs are immutable.
File names contain an ordering prefix and a readable name. Human-facing references always
link the issue title.

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
  An empty section is written as `None.`. These links are the sole source of blocking edges.
- **Query the frontier:** select open children whose assignee is `null` and whose blockers
  are all closed, ordered by `order`, then ID. The command below reads the current files;
  do not maintain an open-ticket list in the map.
- **Claim first:** set `assignee` to the developer driving the effort before ticket work.
  A delegated agent records its identity in a separate claim comment. Re-read the issue
  before changing it and do not take an already assigned ticket.
- **Resolve:** add a resolution comment under `comments/<issue-id>/`, with the answer or
  a link to its research asset and relevant evidence. Set the issue to `closed`, then
  append a one-line gist linking the issue title to the map's Decisions so far.
- **Release a claim:** set `assignee` back to `null` if work stops before resolution.
- **Exclude:** close a mis-scoped issue with an explanation, and link it only from the map's
  Out of scope section.
- **Concurrent edits:** separate tickets can be worked independently. Serialize edits to the
  map index, re-read before patching, and use patches that preserve other sessions' entries.
  Claims are file-based; coordinate if two sessions attempt to claim at the same time.

Run this read-only frontier query from the repository root (Python standard library only).
Replace `<effort>` with the effort directory name and `<map-id>` with its map issue ID.
Each query selects the ready children of one map; repeat for other efforts as needed:

```sh
python3 - '.scratch/<effort>/issues' '<map-id>' <<'PY'
from pathlib import Path
import re
import sys

issue_dir = Path(sys.argv[1]).resolve()
map_id = sys.argv[2]
if not issue_dir.is_dir():
    raise SystemExit(f"Issue directory does not exist: {issue_dir}")
issues = {}
for path in issue_dir.glob("*.md"):
    header, body = path.read_text().split("---", 2)[1:]
    metadata = dict(line.split(": ", 1) for line in header.strip().splitlines())
    section = body.split("## Blocked by\n", 1)
    blocked_by = []
    if len(section) == 2:
        block = section[1].split("\n## ", 1)[0]
        blocked_by = [
            (path.parent / target).resolve()
            for target in re.findall(r"\]\(([^)]+)\)", block)
        ]
    issues[path.resolve()] = (metadata, blocked_by)

for path, (item, blockers) in sorted(
    issues.items(), key=lambda entry: (int(entry[1][0]["order"]), entry[1][0]["id"])
):
    if item["parent"] != map_id or item["status"] != "open":
        continue
    if item["assignee"] != "null":
        continue
    if any(blocker not in issues or issues[blocker][0]["status"] != "closed"
           for blocker in blockers):
        continue
    print(f'{item["title"]} — {path.relative_to(Path.cwd())}')
PY
```

Keep blocking links within the effort so the query can resolve their status. Missing
blockers are treated as unresolved and keep the issue out of the frontier.

Research worktrees may retain uncommitted findings on a `research/<name>` branch; record the
branch and worktree in the ticket's comments and keep the reviewable asset in `docs/research/`.
Repository instructions prohibit creating commits without the user's explicit request.
