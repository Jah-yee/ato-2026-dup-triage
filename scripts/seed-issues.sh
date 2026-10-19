#!/usr/bin/env bash
# Create the workshop's seeded issues in the BASE repo.
#
#   scripts/seed-issues.sh                 # DRY RUN (default): print the commands, write nothing
#   scripts/seed-issues.sh --apply         # really create the issues with gh
#   scripts/seed-issues.sh --repo OWNER/NAME [--apply]
#
# Safe to re-run: with --apply it first lists every issue title already in the
# repo (open and closed) and skips those, so a second run creates nothing.
#
# Issues are created in seed order, one at a time, and the run stops at the
# first failure. In a FRESH repo (no issues, no pull requests yet) the first
# seeded issue becomes #1, which is what data/issues.json and answer-key.md
# assume. If a number comes out different, the script says so: then run
# scripts/refresh-offline-data.sh and update the numbers in answer-key.md.
#
# Needs: python3 (3.9+). --apply also needs gh, signed in with an account that
# can create issues in the repo (the owner's, never an attendee's).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 - "$HERE/../seed/issues.json" "$@" <<'PY'
import json
import shlex
import subprocess
import sys

DEFAULT_REPO = "KiroCrewCaptain/ato-2026-dup-triage"

seed_path, *args = sys.argv[1:]
repo, apply = DEFAULT_REPO, False
i = 0
while i < len(args):
    a = args[i]
    if a == "--apply":
        apply = True
    elif a == "--repo" and i + 1 < len(args):
        repo = args[i + 1]
        i += 1
    elif a in ("-h", "--help"):
        print("usage: seed-issues.sh [--repo OWNER/NAME] [--apply]\n"
              "Default is a dry run that prints the gh commands and writes nothing.")
        sys.exit(0)
    else:
        sys.exit(f"unknown argument: {a}\nusage: seed-issues.sh [--repo OWNER/NAME] [--apply]")
    i += 1

with open(seed_path, encoding="utf-8") as fh:
    seed = json.load(fh)


def gh(*cmd, stdin=None):
    return subprocess.run(["gh", *cmd], input=stdin, text=True, capture_output=True)


def command(issue):
    cmd = ["gh", "issue", "create", "-R", repo, "--title", issue["title"], "--body-file", "-"]
    for label in issue["labels"]:
        cmd += ["--label", label]
    return cmd


if not apply:
    print(f"# DRY RUN: nothing is written. Target repo: {repo}")
    print(f"# {len(seed)} issues, created in this order. Each body is sent on stdin (--body-file -).")
    print("# Re-run with --apply to create them. --apply skips titles that already exist.")
    for n, issue in enumerate(seed, start=1):
        print(f"# expected #{n}  ({len(issue['body'])} chars of body)")
        print(shlex.join(command(issue)) + " <<'BODY'")
        print("...")
        print("BODY")
    sys.exit(0)

# ---- --apply ----
probe = gh("repo", "view", repo, "--json", "nameWithOwner,hasIssuesEnabled")
if probe.returncode != 0:
    sys.exit(f"cannot read {repo}: {probe.stderr.strip()}")
if not json.loads(probe.stdout).get("hasIssuesEnabled"):
    sys.exit(f"{repo} has Issues turned off. Turn them on (Settings -> General -> Features -> Issues).")

labels = gh("label", "list", "-R", repo, "--limit", "200", "--json", "name")
if labels.returncode != 0:
    sys.exit(f"cannot list labels: {labels.stderr.strip()}")
have = {x["name"] for x in json.loads(labels.stdout)}
need = {l for issue in seed for l in issue["labels"]}
missing = sorted(need - have)
if missing:
    sys.exit(f"{repo} is missing labels {missing}. They are GitHub defaults; re-create them first.")

existing = gh("issue", "list", "-R", repo, "--state", "all", "--limit", "1000", "--json", "title")
if existing.returncode != 0:
    sys.exit(f"cannot list issues: {existing.stderr.strip()}")
titles = {x["title"] for x in json.loads(existing.stdout)}

created = skipped = 0
shifted = []
for n, issue in enumerate(seed, start=1):
    if issue["title"] in titles:
        print(f"skip  #{n}: already exists: {issue['title']}")
        skipped += 1
        continue
    res = subprocess.run(command(issue), input=issue["body"], text=True, capture_output=True)
    if res.returncode != 0:
        sys.exit(f"FAILED on seed issue {n} ({issue['title']}): {res.stderr.strip()}\n"
                 f"created {created}, skipped {skipped}. Fix the cause and re-run; existing titles are skipped.")
    url = res.stdout.strip().splitlines()[-1]
    got = url.rsplit("/", 1)[-1]
    print(f"made  #{got}: {issue['title']}")
    if got != str(n):
        shifted.append((n, got))
    created += 1

print(f"done: created {created}, skipped {skipped}")
if shifted:
    print("WARNING: some numbers differ from seed order (expected -> got): "
          + ", ".join(f"{a}->{b}" for a, b in shifted))
    print("Run scripts/refresh-offline-data.sh and update the numbers in answer-key.md.")
PY
