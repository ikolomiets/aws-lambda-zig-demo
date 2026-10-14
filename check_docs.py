"""Check repository Markdown destinations without executing examples."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import sys
from urllib.parse import unquote, urlsplit


DEFINITION = re.compile(
    r"^\s{0,3}\[([^\]\n]+)\]:\s*(<[^>\n]+>|\S+)", re.MULTILINE,
)
ZIG_VALUE_OPTIONS = {
    "--build-file", "--cache-dir", "--global-cache-dir", "--zig-lib-dir", "--prefix",
    "--prefix-lib-dir", "--prefix-exe-dir", "--prefix-include-dir", "--search-prefix",
    "--sysroot", "--libc", "--color", "--summary", "--seed", "--maxrss", "--system", "-p",
}


def build_names(root):
    path = root / "build.zig"
    if not path.is_file():
        return set(), set()
    text = path.read_text(encoding="utf-8")
    # Preserve quoted strings while discarding comments that may mention old declarations.
    text = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/',
                  lambda match: "" if match[0].startswith(("//", "/*")) else match[0],
                  text, flags=re.DOTALL)
    targets = set(re.findall(r'\b\w+\.step\(\s*"([^"\\]+)"', text))
    targets.update(("install", "uninstall"))  # Zig's built-in steps.
    executables = set(re.findall(
        r'\b\w+\.addExecutable\(\s*\.\{[^}]*?\.name\s*=\s*"([^"\\]+)"', text,
        flags=re.DOTALL,
    ))
    return targets, executables


def mask_comments(text):
    """Preserve code literals and source positions while masking real comments."""
    syntax = re.compile(r"(?m)^ {0,3}(`{3,}|~{3,})([^\r\n]*)|<!--|`+|\\[^\r\n]")
    parts = []
    position = 0
    fence = None
    while match := syntax.search(text, position):
        parts.append(text[position:match.start()])
        value = match[0]
        end = match.end()
        if match[1]:
            fence = fence_transition(fence, match)
        elif fence is None and value == "<!--":
            closing = text.find("-->", end)
            end = len(text) if closing == -1 else closing + 3
            value = text[match.start():end]
            if not re.fullmatch(
                r"<!-- doc-check: commands=(current|planning|historical) -->", value,
            ):
                value = re.sub(r"[^\r\n]", " ", value)
        elif fence is None and value.startswith("`"):
            closing = re.compile(r"(?<!`)" + re.escape(value) + r"(?!`)").search(text, end)
            if closing:
                end = closing.end()
                value = text[match.start():end]
        parts.append(value)
        position = end
    parts.append(text[position:])
    return "".join(parts)


def command_examples(text):
    text = mask_comments(text)
    fence = None
    shell = False
    pending = ""
    start = 0
    mode = "current"
    for number, line in enumerate(text.splitlines(), 1):
        directive = re.fullmatch(
            r"\s*<!-- doc-check: commands=(current|planning|historical) -->\s*", line,
        )
        if directive and fence is None:
            mode = directive[1]
            continue
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})(.*)$", line)
        if marker:
            next_fence = fence_transition(fence, marker)
            if fence is None:
                shell = (mode == "current" and
                         marker[2].strip() in ("sh", "bash", "shell", "console"))
            elif next_fence is None:
                shell = False
            fence = next_fence
            continue
        if shell:
            if not pending:
                start = number
            pending += line.removesuffix("\\") + " "
            if not line.endswith("\\"):
                yield start, pending
                pending = ""
        elif fence is None and mode == "current":
            for match in re.finditer(r"`([^`\n]+)`", line):
                yield number, match[1]


def command_errors(root, example, targets, executables):
    try:
        lexer = shlex.shlex(example, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return []  # Partial snippets are outside the shell syntax check's scope.
    errors = []
    segments = []
    segment = []
    for token in tokens + [";"]:
        if re.fullmatch(r"[;&|()]+", token):
            if segment:
                segments.append(segment)
            segment = []
        else:
            segment.append(token)
    for segment in segments:
        while segment and (re.match(r"^[A-Za-z_]\w*=", segment[0]) or
                           segment[0] in ("$", "env", "sudo")):
            segment = segment[1:]
        if not segment:
            continue
        entry = segment[0]
        if segment[:2] == ["zig", "build"]:
            skip_value = False
            for token in segment[2:]:
                if token == "--":
                    break
                if skip_value:
                    skip_value = False
                elif token in ZIG_VALUE_OPTIONS:
                    skip_value = True
                elif not token.startswith("-") and token not in targets:
                    errors.append(f"unknown Zig build target: {token}")
        elif entry in ("bash", "sh", "python3", "python"):
            operands = [token for token in segment[1:] if not token.startswith("-")]
            if operands and operands[0].endswith((".sh", ".py")):
                entry = operands[0]
            else:
                continue
        elif not entry.startswith(("./", "zig-out/bin/")):
            continue
        else:
            entry = entry.removeprefix("./")
        if entry == "zig":
            continue
        if entry.startswith("zig-out/bin/"):
            if entry.removeprefix("zig-out/bin/") not in executables:
                errors.append(f"missing repository entry point: {entry}")
        elif not (root / entry).is_file():
            errors.append(f"missing repository entry point: {entry}")
    return errors


def reference_key(label):
    return " ".join(label.casefold().split())


def closing_delimiter(text, start):
    opening = text[start]
    closing = {"[": "]", "(": ")"}[opening]
    depth = 1
    position = start + 1
    destination_start = position
    while destination_start < len(text) and text[destination_start].isspace():
        destination_start += 1
    literal_end = None
    while position < len(text):
        if text[position] == "\\":
            position += 2
            continue
        if literal_end is not None:
            if text[position] == literal_end:
                literal_end = None
            position += 1
            continue
        if opening == "(" and position == destination_start and text[position] == "<":
            literal_end = ">"
        elif (opening == "(" and text[position] in ("'", '"') and
              text[position - 1].isspace()):
            literal_end = text[position]
        if text[position] == opening:
            depth += 1
        elif text[position] == closing:
            depth -= 1
            if depth == 0:
                return position
        position += 1
    return None


def link_spans(text):
    """Recognize balanced labels/destinations, including multiline inline links."""
    position = 0
    while position < len(text):
        if text[position] == "\\":
            position += 2
            continue
        if text[position] != "[":
            position += 1
            continue
        start = position
        closing = closing_delimiter(text, start)
        if closing is None:
            position += 1
            continue
        label = text[start + 1:closing]
        position = closing + 1
        if position < len(text) and text[position] == "(":
            end = closing_delimiter(text, position)
            if end is not None:
                body = text[position + 1:end].strip()
                destination = re.match(r"<([^>]+)>|([^\s]+)", body)
                value = (destination[1] or destination[2]) if destination else ""
                yield start, end + 1, label, "inline", value
                position = end + 1
                continue
        if not label.strip():
            continue
        reference_start = position
        while reference_start < len(text) and text[reference_start].isspace():
            reference_start += 1
        if reference_start < len(text) and text[reference_start] == "[":
            end = closing_delimiter(text, reference_start)
            if end is not None:
                value = text[reference_start + 1:end] or label
                yield start, end + 1, label, "reference", value
                position = end + 1
                continue
        yield start, position, label, "shortcut", label


def document_links(text):
    rendered = "\n".join(line for _, line in markdown_lines(text))
    rendered = re.sub(r"(`+).*?\1", lambda match: "\n" * match[0].count("\n"),
                      rendered, flags=re.DOTALL)
    definitions = {}
    for match in DEFINITION.finditer(rendered):
        definitions.setdefault(reference_key(match[1]), match[2].strip("<>"))
    rendered = DEFINITION.sub(lambda match: "\n" * match[0].count("\n"), rendered)
    for start, _, _, kind, value in link_spans(rendered):
        number = rendered.count("\n", 0, start) + 1
        if kind == "inline":
            yield number, re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])", r"\1", value)
            continue
        key = reference_key(value)
        if kind == "reference" or key in definitions:
            yield number, definitions.get(key, f"[undefined reference: {key}]")


def fence_transition(fence, marker):
    if fence is None:
        return marker[1]
    if (marker[1][0] == fence[0] and len(marker[1]) >= len(fence)
            and not marker[2].strip(" \t")):
        return None
    return fence


def markdown_lines(text):
    """Exclude fenced examples and comments from rendered Markdown."""
    text = mask_comments(text)
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})(.*)$", line)
        if marker:
            fence = fence_transition(fence, marker)
            yield number, ""
        else:
            yield number, line if fence is None else ""


def heading_anchors(text):
    anchors = set()
    counts = {}
    previous = ""
    for _, line in markdown_lines(text):
        anchors.update(re.findall(r'<[^>]+\b(?:id|name)=[\'"]([^\'"]+)[\'"]', line))
        heading = re.match(r"^\s{0,3}#{1,6}\s+(.+?)(?:\s+#+)?\s*$", line)
        title = heading[1] if heading else None
        if previous.strip() and re.fullmatch(r"\s{0,3}(?:=+|-+)\s*", line):
            title = previous.strip()
        if title:
            for start, end, label, kind, _ in reversed(list(link_spans(title))):
                if kind != "shortcut":
                    title = title[:start] + label + title[end:]
            title = re.sub(r"<[^>]+>", "", title)
            slug = re.sub(r"[^\w\- ]", "", title.lower()).replace(" ", "-")
            count = counts.get(slug, 0)
            counts[slug] = count + 1
            anchors.add(f"{slug}-{count}" if count else slug)
        previous = line
    return anchors


def has_anchor(target, fragment):
    text = target.read_text(encoding="utf-8")
    lines = re.fullmatch(r"L([1-9]\d*)(?:-L([1-9]\d*))?", fragment)
    if lines:
        first = int(lines[1])
        last = int(lines[2] or lines[1])
        return first <= last <= len(text.splitlines())
    return target.suffix.lower() == ".md" and fragment in heading_anchors(text)


def read_archives(root):
    path = root / "docs/agents/documentation-archives.json"
    if not path.is_file():
        return {}
    records = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(records, dict):
        raise ValueError(f"{path}: archive records must be an object")
    for name, record in records.items():
        if (not isinstance(record, dict) or not isinstance(record.get("reason"), str) or
                not record["reason"].strip() or
                not re.fullmatch(r"[a-f0-9]{64}", str(record.get("sha256", "")))):
            raise ValueError(f"{path}: invalid archive record: {name}")
        source = root / name
        if not source.is_relative_to(root) or ".." in source.parts or Path(name).is_absolute():
            raise ValueError(f"{path}: archive must be a repository file: {name}")
        if not source.exists():
            continue
        if hashlib.sha256(source.read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError(f"{name}: archive checksum mismatch")
    return records


def check_document(root, source, targets, executables, archives):
    errors = []
    text = source.read_text(encoding="utf-8")
    archived = source.relative_to(root).as_posix() in archives
    local_evidence = 0
    for number, destination in document_links(text):
        url = urlsplit(destination)
        machine_local = destination.startswith(("/", "file:", "~/"))
        if archived and machine_local:
            local_evidence += 1
            continue
        if (url.scheme and url.scheme != "file") or url.netloc:
            continue
        target = source.parent / unquote(url.path) if url.path else source
        reason = None
        if machine_local or not target.resolve().is_relative_to(root):
            reason = "nonportable local destination (not declared archival evidence)"
        elif not target.exists():
            reason = "missing repository target"
        elif url.fragment:
            if not target.is_file() or not has_anchor(target, unquote(url.fragment)):
                reason = "missing anchor"
        if reason:
            errors.append(f"{source.relative_to(root)}:{number}: {reason}: {destination}")
    if archived:
        print(f"{source.relative_to(root)}: {local_evidence} archival machine-local evidence "
              f"links; historical commands; {archives[source.relative_to(root).as_posix()]['reason']}")
    else:
        for number, example in command_examples(text):
            for error in command_errors(root, example, targets, executables):
                errors.append(f"{source.relative_to(root)}:{number}: {error}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("paths", nargs="*", help="Markdown files relative to the repository root")
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    sources = ([root / name for name in arguments.paths] if arguments.paths else
               sorted(root.glob("*.md")) + sorted((root / "docs").rglob("*.md")))
    try:
        if not root.is_dir():
            raise ValueError(f"repository root is not a directory: {root}")
        for source in sources:
            if not source.resolve().is_relative_to(root):
                raise ValueError(f"document must be inside the repository root: {source}")
        targets, executables = build_names(root)
        archives = read_archives(root)
        errors = [error for source in sources
                  for error in check_document(root, source, targets, executables, archives)]
    except (OSError, ValueError) as error:
        print(f"Documentation check: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Checked {len(sources)} Markdown files; {len(errors)} errors.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
