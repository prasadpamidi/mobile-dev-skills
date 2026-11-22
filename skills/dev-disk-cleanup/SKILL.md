---
name: dev-disk-cleanup
description: >-
  Find and reclaim disk space on a macOS mobile-dev machine: merged or dead git worktrees, Xcode
  DerivedData (including private build folders left in agent scratchpads and /tmp), simulator
  devices and runtimes, DeviceSupport, package-manager and agent caches. Use when the disk is
  filling up, a build fails with "no space left on device", or the user asks to clean worktrees,
  DerivedData, simulators, or caches.
---

# Dev Disk Cleanup

`scripts/disk-cleanup.sh` measures where space goes and removes what is safe, with a confirmation
before every deletion. Your job: run the read-only report, show the user what is reclaimable,
get their approval per category, then run only the approved cleanups non-interactively.

Run the script from this skill's directory, for example `bash <skill-dir>/scripts/disk-cleanup.sh`.
Scans walk the whole home folder and can take minutes: run them in the background or with a long
timeout, and never start a second copy while one is running.

## Workflow

### 1. Measure (read-only)

```sh
bash scripts/disk-cleanup.sh --analyze </dev/null
```

It prints the disk status, the biggest categories, and a "What you can reclaim" list in which each
line names its menu entry. Pass `--developer-storage` for agent, MCP, and temp details.

### 2. Review before deleting

For worktrees, list them first. Nothing is removed without `--pick`:

```sh
bash scripts/disk-cleanup.sh --worktrees </dev/null
```

The status column means:

- `merged`: the commit is in the default branch, or GitHub (via `gh`) shows a merged PR whose head
  is exactly this commit. Squash merges count. Safe.
- `prunable`: the folder is already gone; only Git's record is left. Safe.
- `dirty`: there are uncommitted or untracked files. Remove only with the user's OK. The script
  first saves a patch and a tarball of untracked files to `~/worktree-backups-<date>/`, skipping
  build-output folders. The branch is kept.
- `orphan`: a detached commit that no branch holds. Never removed.
- `idle`: clean but not merged. Removing it keeps the branch. Ask first.

For DerivedData, `stale` means the project path is gone (safe), and `live` means the project still
exists (rebuilds from scratch if deleted, so ask first). Temp builds are rebuildable, but warn if
one was touched in the last two hours: a build may be running.

Tell the user the size and the list for each category, then ask which to remove. Approval for one
category does not extend to the others.

### 3. Clean what was approved

Every mode is non-interactive with `--pick SPEC` (answers pickers: `s` = the safe set, `3 5-7`,
`all`) and `--yes` (answers confirmations). Do a `--dry-run` first when the selection is broad.

```sh
bash scripts/disk-cleanup.sh --worktrees --pick s --yes </dev/null          # merged + missing
bash scripts/disk-cleanup.sh --worktrees --pick "2 4" --yes </dev/null      # specific rows
bash scripts/disk-cleanup.sh --derived-data --pick s --yes </dev/null       # stale DerivedData
bash scripts/disk-cleanup.sh --temp-builds --pick "1 3" --yes </dev/null    # scratchpad/tmp builds
bash scripts/disk-cleanup.sh --safe-all </dev/null                          # zero-risk set only
```

Row numbers come from the listing you just showed. Re-list if anything changed since then, because
numbers shift after deletions. Run worktrees before DerivedData: removing a worktree makes its
DerivedData `stale`.

### 4. Report

Re-run `--analyze` or `df -h /System/Volumes/Data`. Report the space freed, anything kept and why,
and where backups were saved.

## Rules

- Never delete a `dirty`, `idle`, or `orphan` worktree, a `live` DerivedData folder, or a simulator
  without the user naming it or its category.
- Don't delete branches, simulators, or runtimes the user didn't ask about. The script deletes a
  worktree's branch only when the work is merged.
- Don't run `rm -rf` yourself on paths the script would handle. Its safety checks (in-use, changed
  since the scan, locked) exist for a reason.
- If a deletion is refused by a sandbox or permission prompt, report it. Don't work around it.
- Log files land in `~/disk-cleanup-<timestamp>.log`. Mention the path when reporting.
