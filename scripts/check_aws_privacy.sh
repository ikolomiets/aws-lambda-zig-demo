#!/usr/bin/env bash
set -euo pipefail

print_usage() {
    printf 'Usage: check_aws_privacy.sh --staged | --base REF [--head REF]\n'
    printf 'Inspect staged content or compare Git trees (--head defaults to HEAD).\n'
}
usage() {
    print_usage >&2
    exit 2
}

mode=
base=
head=HEAD
head_set=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --staged)
            [ -z "$mode" ] || usage
            mode=staged
            shift
            ;;
        --base)
            [ "$#" -ge 2 ] && [ -z "$mode" ] || usage
            mode=range
            base="$2"
            shift 2
            ;;
        --base=*)
            [ -z "$mode" ] || usage
            mode=range
            base="${1#--base=}"
            shift
            ;;
        --head)
            [ "$#" -ge 2 ] && [ "$head_set" -eq 0 ] || usage
            head="$2"
            head_set=1
            shift 2
            ;;
        --head=*)
            [ "$head_set" -eq 0 ] || usage
            head="${1#--head=}"
            head_set=1
            shift
            ;;
        -h|--help) print_usage; exit 0 ;;
        *) usage ;;
    esac
done
[ -n "$mode" ] || usage
[ "$mode" = range ] || [ "$head_set" -eq 0 ] || usage

fail_check() {
    printf 'AWS privacy check could not read its inputs; no passing result recorded.\n' >&2
    exit 2
}
command -v git >/dev/null || fail_check
command -v jq >/dev/null || fail_check
work="$(mktemp -d "${TMPDIR:-/tmp}/aws-privacy.XXXXXX")" || fail_check
trap 'rm -rf "$work"' EXIT

git_read() {
    git --literal-pathspecs "$@" 2>"$work/git-error" || fail_check
}

if [ "$mode" = staged ]; then
    selection=(--cached)
    content_ref=:
else
    # Pin both trees so patch selection and full blob reads use identical inputs.
    base_tree="$(git_read rev-parse --verify --end-of-options "$base^{tree}")"
    head_tree="$(git_read rev-parse --verify --end-of-options "$head^{tree}")"
    selection=("$base_tree" "$head_tree")
    content_ref="$head_tree:"
fi

# jq is already a project prerequisite. Keep its filtering within this shell
# entry point, and emit only categories and locations, never matched values.
cat >"$work/filter" <<'JQ'
def categories:
    gsub("(?i)\\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\\b"; " ") as $text
    | [
        ["AWS access key ID", "\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b", ""],
        ["IAM principal ID", "\\b(?:AIDA|AROA|AGPA|AIPA|ANPA|ANVA|ASCA)[A-Z0-9]{16,20}\\b", ""],
        ["AWS account ID", "(?<![A-Za-z0-9])[0-9]{12}(?![A-Za-z0-9])", ""],
        ["AWS credential value",
         "[\"']?(?:aws[-_]?)?(?:secret[-_]?access[-_]?key|session[-_]?token)[\"']?\\s*[:=]\\s*(?:!Sub\\s+)?[\"']?[A-Za-z0-9/+=]{16,}", "i"],
        ["AWS deployment endpoint",
         "\\b[a-z0-9-]+\\.(?:lambda-url\\.[a-z0-9-]+\\.on\\.aws|execute-api\\.[a-z0-9-]+\\.amazonaws\\.com(?:\\.cn)?|cloudfront\\.net|[a-z0-9.-]*elb\\.amazonaws\\.com)", "i"],
        ["S3 bucket reference",
         "\\bs3://[a-z0-9][a-z0-9.-]*(?=[/\\s\"'\u0060]|$)|\\b[a-z0-9][a-z0-9.-]*\\.s3(?:[.-][a-z0-9-]+)?\\.amazonaws\\.com(?:\\.cn)?|\\bs3(?:[.-][a-z0-9-]+)?\\.amazonaws\\.com(?:\\.cn)?/[a-z0-9][a-z0-9.-]*", "i"],
        ["S3 bucket value",
         "[\"']?(?:s3[-_]?bucket(?:[-_]?name)?|bucket[-_]?name)[\"']?\\s*[:=]\\s*[\"']?[a-z0-9][a-z0-9.-]{2,}", "i"]
      ][]
    | . as $rule
    | select($text | test($rule[1]; $rule[2]))
    | $rule[0];

def finding($number; $text):
    $text | categories | {path: $path, line: $number, category: .};

foreach inputs as $text (0; . + 1;
    if $mode == "full" then finding(.; $text)
    else
        ($text | index("\t")) as $separator
        | finding(($text[:$separator] | tonumber); $text[$separator + 1:])
    end
)
JQ

common=(--no-ext-diff --no-textconv --no-renames)
git_read diff "${common[@]}" --name-status -z --diff-filter=AMT "${selection[@]}" -- >"$work/entries"
: >"$work/findings"
while IFS= read -r -d '' status; do
    IFS= read -r -d '' path || fail_check
    case "/$path" in
        */.aws/credentials|*/.aws/config|*/.aws/sso/cache/*)
            jq -nc --arg path "$path" \
                '{path: $path, line: 1, category: "AWS credential/config/cache file"}' \
                >>"$work/findings" 2>"$work/jq-error" || fail_check
            ;;
    esac

    scan_mode=full
    if [ "$status" = A ]; then
        git_read show "$content_ref$path" >"$work/lines"
    else
        git_read diff "${common[@]}" --unified=0 "${selection[@]}" -- "$path" >"$work/patch"
        if grep -q '^Binary files ' "$work/patch"; then
            git_read show "$content_ref$path" >"$work/lines"
        else
            scan_mode=added
            awk '
                /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ {
                    split($3, position, ",")
                    sub(/^\+/, "", position[1])
                    number = position[1] + 0
                    active = 1
                    next
                }
                active && substr($0, 1, 1) == "+" {
                    printf "%d\t%s\n", number, substr($0, 2)
                    number++
                    next
                }
                active && substr($0, 1, 1) == " " { number++ }
            ' "$work/patch" >"$work/lines" || fail_check
        fi
    fi
    jq -Rnc --arg path "$path" --arg mode "$scan_mode" -f "$work/filter" \
        <"$work/lines" >>"$work/findings" 2>"$work/jq-error" || fail_check
done <"$work/entries"

if [ -s "$work/findings" ]; then
    jq -sr 'unique_by([.path, .line, .category]) | .[] |
        (.path | tojson) + ":" + (.line | tostring) + ": " + .category + " (value redacted)"' \
        "$work/findings" 2>"$work/jq-error" || fail_check
    printf 'Review candidates and replace private values with placeholders before publishing.\n' >&2
    exit 1
fi
printf 'AWS privacy check passed for the selected changes.\n'
