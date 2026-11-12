#!/usr/bin/env bash
# Spec 019: sync private main to the public repo as one fast-forward squash commit.
#
#   scripts/public-sync.sh [--dry-run] [--public PATH_OR_URL] [--source REV|worktree] [--repo DIR] [--branch main]
#
# The public tree = the private tree minus the paths in .public-exclude. The leak gate
# (scripts/public_leak_gate.py) must pass on that tree and on the commit, or nothing is pushed.
# --dry-run builds the tree and the commit, runs the gate, lists the changed files and keeps the
# temporary directory; it pushes nothing and changes no repo. Without --public a dry run only
# builds and gates the tree. --source worktree uses the working tree (tracked and untracked,
# not ignored) instead of a commit.
#
# Test overrides: --exclude-file, --corpus, --patterns replace the files read from the private tree.
# PUBLIC_SYNC_BEFORE_PUSH: a command run just before the push (tests use it to simulate a race).
# TAIPO_PYTHON: the Python interpreter (default python3); it always runs with -I.
set -euo pipefail

NOREPLY_NAME="Eric Chang"
NOREPLY_EMAIL="10594519+unknowntpo@users.noreply.github.com"
PUBLIC_SLUG="unknowntpo/taipo"

dry_run=0 public="" source_rev="HEAD" repo="." branch="main"
exclude_file="" corpus="" patterns=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --public) public="$2"; shift 2 ;;
    --source) source_rev="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --exclude-file) exclude_file="$2"; shift 2 ;;
    --corpus) corpus="$2"; shift 2 ;;
    --patterns) patterns="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

fail() { echo "public-sync: $*; fail closed" >&2; exit 1; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }

gate_py="$(cd "$(dirname "$0")" && pwd)/public_leak_gate.py"
python="${TAIPO_PYTHON:-python3}"
repo="$(git -C "$repo" rev-parse --show-toplevel)"
pgit() { git -C "$repo" "$@"; }
work="$(mktemp -d "${TMPDIR:-/tmp}/public-sync.XXXXXX")"
if [ "$dry_run" -eq 0 ]; then trap 'rm -rf "$work"' EXIT; fi

# 1. The private tree.
if [ "$source_rev" = worktree ]; then
  index="$work/index"
  if [ -f "$(pgit rev-parse --path-format=absolute --git-path index)" ]; then cp "$(pgit rev-parse --path-format=absolute --git-path index)" "$index"; fi
  GIT_INDEX_FILE="$index" pgit add -A
  tree="$(GIT_INDEX_FILE="$index" pgit write-tree)"
  private_sha="$(pgit rev-parse --verify HEAD)"
else
  private_sha="$(pgit rev-parse --verify "$source_rev^{commit}")"
  tree="$(pgit rev-parse "$private_sha^{tree}")"
fi
echo "private: $private_sha"

# 2. Inputs read from the private tree (fail closed when missing or empty).
from_tree() { # <path-in-tree> <override> <dest>
  if [ -n "$2" ]; then cp "$2" "$3" 2>/dev/null || fail "$1 override not found"
  elif pgit cat-file -e "$tree:$1" 2>/dev/null; then pgit cat-file blob "$tree:$1" > "$3"
  else fail "$1 not found"; fi
  grep -q '[^[:space:]]' "$3" || fail "$1 is empty"
}
from_tree .public-exclude "$exclude_file" "$work/exclude"
from_tree private/asr-eval/sentences.tsv "$corpus" "$work/corpus.tsv"
from_tree private/leak-patterns.txt "$patterns" "$work/patterns.txt"

# 3. The public tree: git archive minus the exclude list (anchored at the root; dir/ = whole directory).
pathspecs=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
  case "$line" in ''|'#'*) continue ;; esac
  line="${line#/}"
  case "$line" in */) pathspecs+=(":(exclude,glob)${line}**") ;; *) pathspecs+=(":(exclude,glob)$line") ;; esac
done < "$work/exclude"
out="$work/tree"
mkdir -p "$out"
pgit archive --format=tar "$tree" . ${pathspecs[@]+"${pathspecs[@]}"} | tar -x -C "$out"
[ "$dry_run" -eq 1 ] && echo "tree: $out"

# The gate writes per-rule counts (and on failure `path:line rule`, paths redacted when they leak)
# to $gate_summary; it goes to the job summary on every path, including dry runs. No file content.
gate_summary="$work/gate.md"
run_gate() { "$python" -I "$gate_py" --tree "$out" --exclude "$work/exclude" --corpus "$work/corpus.tsv" \
  --patterns "$work/patterns.txt" --summary "$gate_summary" "$@"; }
gate_failed() {
  summary "Private \`$private_sha\` — leak gate failed; nothing pushed."; summary "$(cat "$gate_summary")"
  fail "leak gate"
}

if [ -z "$public" ]; then
  [ "$dry_run" -eq 1 ] || fail "--public is required without --dry-run"
  run_gate || gate_failed
  echo "gate: ok"
  summary "Dry run: private \`$private_sha\` — public tree built and gated (no public repo given)."; summary "$(cat "$gate_summary")"
  exit 0
fi

# 4. The public repo, cloned into the temporary directory (the given repo is never changed).
pub="$work/public.git"
git clone -q --bare --single-branch --branch "$branch" "$public" "$pub" 2>/dev/null || fail "cannot clone $branch of the public repo"
qgit() { git -C "$pub" "$@"; }
public_head="$(qgit rev-parse --verify "refs/heads/$branch")"
echo "public: $public_head"

# 5. Every public commit since the last sync is a sync commit or was ported into private main.
last_sync="$(qgit log --format=%H -1 --grep '^Synced-From: ' "$public_head" || true)"
range="$public_head"; [ -n "$last_sync" ] && range="$last_sync..$public_head"
ported="$(pgit log --format=%B "$private_sha" | sed -n "s|^Ported-From: $PUBLIC_SLUG@\([0-9a-f]\{7,40\}\)\$|\1|p")"
foreign=""
for c in $(qgit rev-list "$range"); do
  if qgit log -1 --format=%B "$c" | grep -q '^Synced-From: '; then continue; fi
  found=0
  for p in $ported; do case "$c" in "$p"*) found=1; break ;; esac; done
  [ "$found" -eq 1 ] || foreign="$foreign $c"
done
[ -z "$foreign" ] || fail "public commits not ported into private main (git am them with Ported-From: $PUBLIC_SLUG@<sha>):$foreign"

# 6. The new public tree, and the no-op case.
index="$work/public-index"
GIT_INDEX_FILE="$index" git --git-dir="$pub" --work-tree="$out" -C "$out" add -A -f .
new_tree="$(GIT_INDEX_FILE="$index" qgit write-tree)"
if [ "$new_tree" = "$(qgit rev-parse "$public_head^{tree}")" ]; then
  run_gate || gate_failed
  echo "gate: ok"
  echo "already in sync"
  [ "$dry_run" -eq 1 ] && summary "Dry run:"
  summary "Private \`$private_sha\` — public \`$public_head\` already in sync."; summary "$(cat "$gate_summary")"
  exit 0
fi
# Printed only after the gate passes: a leaking path must not reach the log.
changes="$(qgit diff-tree -r --no-renames --name-status "$public_head^{tree}" "$new_tree")"
nchanges="$(printf '%s\n' "$changes" | wc -l | tr -d ' ')"

# 7. The commit message: private first-parent titles since the last sync, without #numbers.
base=""
if [ -n "$last_sync" ]; then
  base="$(qgit log -1 --format=%B "$last_sync" | sed -n 's/^Synced-From: \([0-9a-f]\{40\}\)$/\1/p' | tail -1)"
  pgit cat-file -e "$base^{commit}" 2>/dev/null || base=""
else
  short="$(printf '%s' "$public_head" | cut -c1-7)"
  base="$(pgit log --format=%H -1 -E --grep "^Ported-From: $PUBLIC_SLUG@$short" "$private_sha" || true)"
fi
titles=""
if [ -n "$base" ]; then
  for c in $(pgit rev-list --first-parent --reverse "$private_sha" "^$base"); do
    if [ "$(pgit rev-list --parents -n1 "$c" | wc -w)" -gt 2 ]; then t="$(pgit log -1 --format=%B "$c" | sed -n 3p)"
    else t="$(pgit log -1 --format=%s "$c")"; fi
    titles="$titles$t"$'\n'
  done
fi
[ -n "$titles" ] || titles="$(pgit log -1 --format=%s "$private_sha")"$'\n'
titles="$(printf '%s' "$titles" | sed -E 's/ ?\(#[0-9]+\)//g; s/#[0-9]+//g; s/[[:space:]]+$//; /^$/d; s/^/- /' | awk 'NR <= 50')"

# External contributors keep credit: authors of Ported-From commits who are not the owner.
coauthors=""
log_range="$private_sha"; [ -n "$base" ] && log_range="$base..$private_sha"
while IFS=$'\t' read -r name email; do
  [ -n "$email" ] || continue
  [ "$email" = "$NOREPLY_EMAIL" ] && continue
  grep -qixF "$email" "$work/patterns.txt" && continue
  line="Co-authored-by: $name <$email>"
  case "$coauthors" in *"$line"*) ;; *) coauthors="$coauthors$line"$'\n' ;; esac
done < <(pgit log --format='%an%x09%ae' -E --grep "^Ported-From: $PUBLIC_SLUG@" "$log_range")

msg="$work/message"
{ printf 'Sync from private main\n\n%s\n\nSynced-From: %s\n' "$titles" "$private_sha"; printf '%s' "$coauthors"; } > "$msg"
commit="$(GIT_AUTHOR_NAME="$NOREPLY_NAME" GIT_AUTHOR_EMAIL="$NOREPLY_EMAIL" \
  GIT_COMMITTER_NAME="$NOREPLY_NAME" GIT_COMMITTER_EMAIL="$NOREPLY_EMAIL" \
  qgit commit-tree --no-gpg-sign "$new_tree" -p "$public_head" -F "$msg")"
qgit cat-file commit "$commit" > "$work/meta"

# 8. The gate on the tree and the commit; then the fast-forward push.
run_gate --meta "$work/meta" || gate_failed
echo "gate: ok"
echo "changes: $nchanges files"
printf '%s\n' "$changes"
changed_list() { summary "<details><summary>$nchanges changed files</summary>"; summary ""
  summary "$(printf '%s\n' "$changes" | sed 's/^/    /')"; summary ""; summary "</details>"; }
if [ "$dry_run" -eq 1 ]; then
  echo "dry run: would push $commit onto $public_head"
  summary "Dry run: private \`$private_sha\` — would push \`$commit\` onto public \`$public_head\`, $nchanges files changed."
  changed_list; summary "$(cat "$gate_summary")"
  exit 0
fi
if [ -n "${PUBLIC_SYNC_BEFORE_PUSH:-}" ]; then sh -c "$PUBLIC_SYNC_BEFORE_PUSH"; fi
qgit push -q "$public" "$commit:refs/heads/$branch" || fail "push rejected (public $branch moved?); rerun the sync"
echo "pushed: $public_head..$commit"
summary "Private \`$private_sha\` — public \`$public_head\` → \`$commit\`, $nchanges files changed."
changed_list; summary "$(cat "$gate_summary")"
