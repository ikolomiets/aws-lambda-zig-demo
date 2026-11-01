# Triage labels

This repository uses Matt Pocock's default triage label names in the local
Markdown issue tracker.

| Canonical state role | Label in this tracker | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate the issue. |
| `needs-info` | `needs-info` | Waiting on the reporter for more information. |
| `ready-for-agent` | `ready-for-agent` | Fully specified and ready for agent implementation. |
| `ready-for-human` | `ready-for-human` | Requires human implementation. |
| `wontfix` | `wontfix` | Will not be actioned. |

The category roles also retain their canonical names: `bug` for broken behavior
and `enhancement` for a new feature or improvement.

## Local tracker usage

Follow the [tracker conventions](issue-tracker.md). Store labels in each issue's
YAML front-matter `labels` inline list. An incoming issue processed by `triage`
carries exactly one category label and one state label. When changing its triage
state, replace the previous state label and preserve unrelated labels.

The front-matter `status` remains the issue lifecycle (`open` or `closed`),
independent of its triage state. Close the issue when the triage outcome calls
for closure, including a `wontfix` disposition, and record the reason in a comment
under `comments/<issue-id>/`.

Decision maps and their decision tickets use `wayfinder:*` labels. Implementation
tickets produced by `to-tickets` are already agent-ready and bypass triage.
