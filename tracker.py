"""Local Markdown tracker operations; Python standard library only."""

import argparse
from dataclasses import dataclass
from datetime import date
from graphlib import CycleError, TopologicalSorter
import json
import os
from pathlib import Path
import re
import sys
import tempfile


@dataclass
class Issue:
    path: Path
    metadata: dict
    body: str
    blockers: list
    source: bytes


class TrackerError(Exception):
    pass


def visible_markdown(text, keep_code=False):
    """Mask comments and optionally fenced code, preserving source offsets."""
    visible = []
    fence = None
    comment = False
    for line in text.splitlines(keepends=True):
        if fence is not None:
            marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
            visible.append(line if keep_code else re.sub(r"[^\r\n]", " ", line))
            if (marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence)
                    and not marker[2].strip()):
                fence = None
            continue
        parts = []
        position = 0
        literals = [match.span() for match in re.finditer(
            r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)", line)]
        while position < len(line):
            if comment:
                closing = line.find("-->", position)
                end = len(line) if closing == -1 else closing + 3
                parts.append(re.sub(r"[^\r\n]", " ", line[position:end]))
                position = end
                comment = closing == -1
            else:
                opening = line.find("<!--", position)
                while opening != -1 and any(start <= opening < end for start, end in literals):
                    opening = line.find("<!--", opening + 4)
                if opening == -1:
                    parts.append(line[position:])
                    break
                parts.append(line[position:opening])
                position = opening
                comment = True
        shown = "".join(parts)
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", shown.rstrip("\r\n"))
        if marker:
            fence = marker[1]
            visible.append(shown if keep_code else re.sub(r"[^\r\n]", " ", shown))
        else:
            visible.append(shown)
    return "".join(visible)


def has_content(text):
    return any(line.strip() for line in visible_markdown(text, keep_code=True).splitlines()
               if not re.match(r"^ {0,3}(`{3,}|~{3,})", line))


def sections(body, heading):
    matches = re.finditer(r"^## " + re.escape(heading) + r"[ \t]*\r?\n(.*?)(?=^## |\Z)",
                          visible_markdown(body), re.MULTILINE | re.DOTALL)
    return [body[match.start(1):match.end(1)] for match in matches]


def recorded_field(text, name):
    values = re.findall(r"^" + re.escape(name) + r":(.*)$", visible_markdown(text), re.MULTILINE)
    return values[0].strip() if len(values) == 1 else None


def is_parent(issue):
    return (bool({"wayfinder:map", "wayfinder:spec"} & set(issue.metadata["labels"]))
            or bool(sections(issue.body, "Problem Statement") and sections(issue.body, "Solution")))


def scalar(value):
    if value.startswith('"'):
        try:
            parsed = json.loads(value)
        except ValueError as error:
            raise TrackerError(f"invalid quoted scalar: {value}") from error
        if isinstance(parsed, str):
            return parsed
    elif value.startswith("'"):
        if re.fullmatch(r"'(?:[^']|'')*'", value):
            return value[1:-1].replace("''", "'")
    elif value and value[0] not in "[]{}&*!|>#" and ": " not in value and " #" not in value:
        return value
    raise TrackerError(f"invalid single-line scalar: {value}")


def parse_labels(value):
    if not value.startswith("[") or not value.endswith("]"):
        raise TrackerError(f"invalid inline labels: {value}")
    remaining = value[1:-1].strip()
    labels = []
    while remaining:
        token = re.match(r'''(?:'(?:[^']|'')*'|"(?:[^"\\]|\\.)*"|[^,\[\]{}'"]+)''', remaining)
        if not token:
            raise TrackerError(f"invalid inline labels: {value}")
        label = scalar(token.group().strip())
        if not label or label == "null":
            raise TrackerError(f"invalid inline label: {value}")
        labels.append(label)
        remaining = remaining[token.end():].strip()
        if remaining:
            if not remaining.startswith(",") or not remaining[1:].strip():
                raise TrackerError(f"invalid inline labels: {value}")
            remaining = remaining[1:].strip()
    return labels


def read_issue(path):
    source = path.read_bytes()
    text = source.decode("utf-8")
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        raise TrackerError("missing opening front matter delimiter")
    end = next((index for index in range(1, len(lines))
                if lines[index].strip() == "---"), None)
    if end is None:
        raise TrackerError("missing closing front matter delimiter")
    metadata = {}
    for line in lines[1:end]:
        match = re.fullmatch(r"([a-z][a-z_]*): (.+)", line.rstrip("\r\n"))
        if not match:
            raise TrackerError(f"malformed metadata: {line.strip()}")
        key, value = match.groups()
        if key in metadata:
            raise TrackerError(f"duplicate metadata field: {key}")
        metadata[key] = parse_labels(value.strip()) if key == "labels" else scalar(value.strip())
    required = ("id", "title", "status", "labels", "parent", "assignee", "mode", "order")
    for key in required:
        if (key not in metadata or metadata[key] == ""
                or (metadata[key] == "null" and key not in ("parent", "assignee"))):
            raise TrackerError(f"missing or empty required metadata: {key}")
    for key in ("id", "parent", "assignee"):
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", metadata[key]):
            raise TrackerError(f"invalid {key}: {metadata[key]}")
    if metadata["status"] not in ("open", "closed"):
        raise TrackerError(f'invalid status: {metadata["status"]}')
    if metadata["mode"] not in ("AFK", "HITL"):
        raise TrackerError(f'invalid mode: {metadata["mode"]}')
    if not re.fullmatch(r"-?\d+", metadata["order"]):
        raise TrackerError(f'invalid numeric order: {metadata["order"]}')
    body = "".join(lines[end + 1:])
    issue = Issue(path, metadata, body, [], source)
    blocks = sections(body, "Blocked by")
    blockers = []
    if not blocks and not is_parent(issue):
        raise TrackerError("missing Blocked by section")
    if len(blocks) > 1:
        raise TrackerError("duplicate Blocked by sections")
    if blocks:
        block = blocks[0].strip()
        if block != "None.":
            if not block:
                raise TrackerError("invalid Blocked by: use None. for an empty section")
            for line in block.splitlines():
                if not line.strip():
                    continue
                match = re.fullmatch(r"(?:- )?\[[^\]]+\]\(([^\s)#?]+\.md)\)\.?", line.strip())
                if not match:
                    raise TrackerError(f"invalid Blocked by link: {line.strip()}")
                target = match.group(1)
                blocker = (path.parent / target).resolve()
                if Path(target).is_absolute() or blocker.parent != path.parent.resolve():
                    raise TrackerError(f"out-of-effort blocker: {target}")
                blockers.append(blocker)
    issue.blockers = blockers
    return issue


def read_issues(root):
    issues = {}
    errors = []
    for path in sorted(root.glob("*/issues/*.md")):
        try:
            issues[path.resolve()] = read_issue(path)
        except (TrackerError, OSError, UnicodeError) as error:
            errors.append(f"{path}: {error}")
    if errors:
        raise TrackerError("\n".join(errors))
    return issues


def validate(issues):
    errors = []
    by_id = {}
    for path, issue in issues.items():
        identity = issue.metadata["id"]
        if identity in by_id:
            errors.append(f"{path}: duplicate ID {identity} also in {by_id[identity].path}")
        by_id[identity] = issue
    parents = {}
    for path, issue in issues.items():
        parent_id = issue.metadata["parent"]
        parents[path] = []
        if parent_id != "null":
            parent = by_id.get(parent_id)
            if parent is None or parent.path.parent != issue.path.parent:
                errors.append(f"{path}: missing parent in effort: {parent_id}")
            elif not is_parent(parent):
                errors.append(f"{path}: parent {parent_id} must be a map or spec")
            else:
                parents[path].append(parent.path.resolve())
        for blocker in issue.blockers:
            if blocker not in issues:
                errors.append(f"{path}: missing blocker: {blocker}")
            elif issue.metadata["status"] == "closed" and issues[blocker].metadata["status"] != "closed":
                if "wontfix" in issue.metadata["labels"]:
                    if not has_exclusion_resolution(issue):
                        errors.append(f"{path}: open blocker {blocker} requires an exclusion resolution for wontfix")
                else:
                    errors.append(f"{path}: successfully closed issue has open blocker: {blocker}")
    for kind, graph in (("parent", parents),
                        ("blocking", {path: issue.blockers for path, issue in issues.items()})):
        try:
            TopologicalSorter(graph).prepare()
        except CycleError as error:
            errors.append(f"{kind} cycle: " + " -> ".join(str(path) for path in error.args[1]))
    if errors:
        raise TrackerError("\n".join(errors))


def find_issue(issues, effort, identity):
    for issue in issues.values():
        if issue.path.parent.parent.name == effort and issue.metadata["id"] == identity:
            return issue
    raise TrackerError(f"issue or effort not found: {effort}/{identity}")


def dated_resolution(filename):
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2})-(?:[a-zA-Z0-9_-]+-)?resolution\.md", filename)
    if not match:
        return False
    try:
        date.fromisoformat(match.group(1))
    except ValueError:
        return False
    return True


def comment_dir(issue):
    return issue.path.parent.parent / "comments" / issue.metadata["id"]


def has_exclusion_resolution(issue):
    for path in sorted(comment_dir(issue).glob("*-resolution.md")):
        if not dated_resolution(path.name):
            continue
        text = path.read_text()
        reasons = sections(text, "Exclusion reason")
        if recorded_field(text, "Disposition") == "excluded" and len(reasons) == 1 and has_content(reasons[0]):
            return True
        # Retain the older prose-only exclusion convention.
        lines = text.splitlines()
        if lines and re.match(r"^# Exclusion(?:\s|$)", lines[0]) and has_content("\n".join(lines[1:])):
            return True
    return False


def complete(issue, issues, filename):
    if issue.metadata["status"] != "open":
        raise TrackerError(f"{issue.path}: completion requires an open issue")
    if issue.metadata["assignee"] == "null":
        raise TrackerError(f"{issue.path}: claim the issue before completion")
    if "wontfix" in issue.metadata["labels"]:
        raise TrackerError(f"{issue.path}: wontfix uses an exclusion resolution, not successful completion")
    for blocker in issue.blockers:
        if issues[blocker].metadata["status"] != "closed":
            raise TrackerError(f"{issue.path}: cannot complete with open blocker: {blocker}")
    criteria = sections(issue.body, "Acceptance criteria")
    items = [line.strip() for line in visible_markdown(criteria[0]).splitlines()
             if re.match(r"\s*(?:[-*+]|\d+[.)])\s+", line)] if len(criteria) == 1 else []
    if not items or any(not re.fullmatch(r"(?:[-*+]|\d+[.)])\s+\[[xX]\]\s+\S.*", item) for item in items):
        raise TrackerError(f"{issue.path}: completion requires checked criteria in one Acceptance criteria section")
    if not dated_resolution(filename):
        raise TrackerError(f"{issue.path}: resolution requires a dated YYYY-MM-DD-resolution.md filename")
    resolution = comment_dir(issue) / filename
    if resolution.resolve().parent != comment_dir(issue).resolve():
        raise TrackerError(f"{issue.path}: resolution must be in this issue's comments")
    text = resolution.read_text()
    if recorded_field(text, "Disposition") != "completed":
        raise TrackerError(f"{resolution}: requires exactly one Disposition: completed outside examples")
    if not recorded_field(text, "Reviewed by"):
        raise TrackerError(f"{resolution}: requires exactly one Reviewed by: <reviewer> outside examples")
    evidence = sections(text, "Acceptance evidence")
    if len(evidence) != 1 or not has_content(evidence[0]):
        raise TrackerError(f"{resolution}: requires nonempty Acceptance evidence")
    status = re.search(rb"(?m)^status: [ \t]*(\S.*?)[ \t]*\r?$", issue.source)
    assert status is not None  # The required status field was parsed above.
    quote = status.group(1)[:1]
    value = quote + b"closed" + quote if quote in (b"'", b'"') else b"closed"
    updated = issue.source[:status.start(1)] + value + issue.source[status.end(1):]
    # Replace only after every check passes; retain all other bytes and file permissions.
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=issue.path.parent, prefix=".tracker-", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            os.fchmod(temporary.fileno(), issue.path.stat().st_mode & 0o777)
            temporary.write(updated)
        if issue.path.read_bytes() != issue.source:
            raise TrackerError(f"{issue.path}: issue changed during completion; re-read before retrying")
        os.replace(temporary_path, issue.path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()
    print(f'Completed {issue.metadata["title"]} — {issue.path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parent / ".scratch",
                        help="tracker root (default: repository .scratch)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate", help="validate all discovered efforts")
    frontier = commands.add_parser("frontier", help="list ready children")
    frontier.add_argument("effort")
    frontier.add_argument("parent")
    completion = commands.add_parser("complete", help="close an issue with recorded reviewed acceptance")
    completion.add_argument("effort")
    completion.add_argument("issue")
    completion.add_argument("--resolution", required=True,
                            help="dated resolution filename in this issue's comments directory")
    args = parser.parse_args()
    try:
        args.root = args.root.resolve()
        issues = read_issues(args.root)
        validate(issues)
        if args.command == "complete":
            issue = find_issue(issues, args.effort, args.issue)
            complete(issue, issues, args.resolution)
            return 0
        if args.command == "frontier":
            parent = find_issue(issues, args.effort, args.parent)
            if not is_parent(parent):
                raise TrackerError(f"{parent.path}: frontier parent must be a map or spec")
    except (TrackerError, OSError, UnicodeError) as error:
        print(error, file=sys.stderr)
        return 1
    if args.command == "validate":
        print(f"Validated {len(issues)} issues.")
        return 0
    for issue in sorted(issues.values(),
                        key=lambda item: (int(item.metadata["order"]), item.metadata["id"])):
        item = issue.metadata
        if issue.path.parent.parent.name != args.effort or item["parent"] != args.parent:
            continue
        if item["status"] != "open" or item["assignee"] != "null":
            continue
        if any(issues[blocker].metadata["status"] != "closed"
               for blocker in issue.blockers):
            continue
        print(f'{item["title"]} — {issue.path.relative_to(args.root)}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
