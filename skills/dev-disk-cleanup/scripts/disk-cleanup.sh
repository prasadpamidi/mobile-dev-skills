#!/bin/bash
# disk-cleanup.sh — interactive Mac disk cleanup tool for heavy iOS dev machines
#
# Usage:
#   ./disk-cleanup.sh                    # insights report, then interactive menu
#   ./disk-cleanup.sh --dry-run          # show what would be deleted, change nothing
#   ./disk-cleanup.sh --analyze          # insights report only, no cleanup
#   ./disk-cleanup.sh --safe-all         # zero-risk cleanups only, no prompts
#   ./disk-cleanup.sh --no-scan          # skip the startup insights scan
#   ./disk-cleanup.sh --worktrees        # worktree review and cleanup only
#   ./disk-cleanup.sh --prune-worktrees  # review missing worktree records only
#   ./disk-cleanup.sh --developer-storage # read-only agent, MCP, and temp breakdown
#   ./disk-cleanup.sh --mcp-builds       # pick XcodeBuildMCP build outputs by workspace
#   ./disk-cleanup.sh --temp-builds      # pick temporary Xcode build directories
#   ./disk-cleanup.sh --agent-caches     # pick Codex and Claude cache directories
#   ./disk-cleanup.sh --derived-data     # pick Xcode DerivedData folders
#
# Non-interactive (agents, scripts): --pick SPEC answers every picker ("s", "3 5-7", "all"),
# --yes answers every confirmation. Without them, prompts read EOF and skip/decline.
#   ./disk-cleanup.sh --worktrees --pick s --yes --dry-run
#   ./disk-cleanup.sh --temp-builds --pick "1 2" --yes
#
# Every destructive action confirms first (unless --safe-all or --yes). Everything is logged.
# Sizes are measured live with `du -x`, so mounted simulator runtime images
# (/Library/Developer/CoreSimulator/Volumes) are never double-counted.
# Git worktrees (menu w): finds repos under ~, flags missing/merged/dirty worktrees.

set -u

# ── Config ─────────────────────────────────────────────────────────────────
DRY_RUN=false
AUTO_SAFE=false
ANALYZE_ONLY=false
STARTUP_SCAN=true
WORKTREES_ONLY=false
PRUNE_WORKTREES=false
DEV_STORAGE_ONLY=false
MCP_BUILDS_ONLY=false
TEMP_BUILDS_ONLY=false
AGENT_CACHES_ONLY=false
DERIVED_ONLY=false
ASSUME_YES=false
PICK=""
PICK_SET=false
LOG="${DISK_CLEANUP_LOG:-$HOME/disk-cleanup-$(date +%Y%m%d-%H%M%S).log}"
TEMP_ROOT="${DISK_CLEANUP_TEMP_ROOT:-/private/tmp}"

DD_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
XCODE_DIR="$HOME/Library/Developer/Xcode"
SIM_DEVICES="$HOME/Library/Developer/CoreSimulator/Devices"
DYLD_ROOT="/Library/Developer/CoreSimulator/Caches/dyld"
OLD_DAYS=90   # DeviceSupport folders untouched this long count as "old"
WT_DEPTH=5       # how deep under ~ to look for git repos
WT_IDLE_DAYS=3   # merged worktrees must be idle this long to be auto-selected
WT_BACKUP_DIR="${DISK_CLEANUP_WT_BACKUP_DIR:-$HOME/worktree-backups-$(date +%Y-%m-%d)}"

while [ "$#" -gt 0 ]; do
    arg=$1; shift
    case "$arg" in
        --pick)
            [ "$#" -ge 1 ] || { echo "--pick needs a value (e.g. s, \"3 5-7\", all)" >&2; exit 2; }
            PICK=$1; PICK_SET=true; shift ;;
        --yes|-y)   ASSUME_YES=true ;;
        --derived-data) DERIVED_ONLY=true ;;
        --dry-run)  DRY_RUN=true ;;
        --safe-all) AUTO_SAFE=true ;;
        --analyze)  ANALYZE_ONLY=true ;;
        --no-scan)  STARTUP_SCAN=false ;;
        --worktrees) WORKTREES_ONLY=true ;;
        --prune-worktrees) WORKTREES_ONLY=true; PRUNE_WORKTREES=true ;;
        --developer-storage) DEV_STORAGE_ONLY=true ;;
        --mcp-builds) MCP_BUILDS_ONLY=true ;;
        --temp-builds) TEMP_BUILDS_ONLY=true ;;
        --agent-caches) AGENT_CACHES_ONLY=true ;;
        -h|--help)
            sed -n '2,27p' "$0" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

HAVE_JQ=false; command -v jq >/dev/null 2>&1 && HAVE_JQ=true
HAVE_XCRUN=false; command -v xcrun >/dev/null 2>&1 && HAVE_XCRUN=true

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi

# ── Helpers ────────────────────────────────────────────────────────────────
log()    { echo "$*" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOG"; }
say()    { echo "$*"; log "$*"; }
header() { echo; echo "${BOLD}${BLUE}━━━ $* ━━━${RESET}"; log ""; log "=== $* ==="; }
warn()   { echo "${YELLOW}⚠  $*${RESET}"; log "WARN: $*"; }
ok()     { echo "${GREEN}✓  $*${RESET}"; log "OK: $*"; }
err()    { echo "${RED}✗  $*${RESET}"; log "ERR: $*"; }
info()   { echo "${DIM}   $*${RESET}"; log "   $*"; }
# Print a line to screen and log (for tables)
row()    { echo "$*"; log "$*"; }

# Size of a path in KB, not crossing mount points; 0 if missing
kb_of() {
    if [ -e "$1" ]; then
        du -xsk "$1" 2>/dev/null | awk '{print $1+0}'
    else
        echo 0
    fi
}

# Human-readable sizes
human_kb() {
    awk -v k="${1:-0}" 'BEGIN{
        if (k >= 1048576)   printf "%.1fG", k/1048576;
        else if (k >= 1024) printf "%.0fM", k/1024;
        else                printf "%dK", k }'
}
human_bytes() { human_kb $(( ${1:-0} / 1024 )); }
size_of()     { human_kb "$(kb_of "$1")"; }

# Days since a path was last modified
age_days() {
    local m; m=$(stat -f %m "$1" 2>/dev/null || echo 0)
    echo $(( ( $(date +%s) - m ) / 86400 ))
}

# Shorten $HOME to ~ for display
tildify() { echo "${1/#$HOME/~}"; }

# ver_lt A B → success if version A < version B (dotted numeric)
ver_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        n = split(a, x, "."); m = split(b, y, ".");
        for (i = 1; i <= (n > m ? n : m); i++) {
            p = x[i] + 0; q = y[i] + 0;
            if (p < q) exit 0; if (p > q) exit 1 }
        exit 1 }'
}

# Turn "1 3 5-7 all" into sorted unique indices within 1..max
parse_selection() {
    local input="$1" max="$2" tok a b i
    for tok in $input; do
        if [ "$tok" = "all" ]; then
            seq 1 "$max"
        elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
            for ((i = a; i <= b; i++)); do
                [ "$i" -ge 1 ] && [ "$i" -le "$max" ] && echo "$i"
            done
        elif [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "$max" ]; then
            echo "$tok"
        fi
    done | sort -un
}

# Ask y/n, default n. Returns 0 for yes.
confirm() {
    if $AUTO_SAFE || $ASSUME_YES; then log "CONFIRM (auto): $1"; return 0; fi
    echo
    printf "${YELLOW}❓ %s${RESET} ${DIM}[y/N]:${RESET} " "$1"
    local ans=""
    read -r ans || true
    [[ "$ans" =~ ^[Yy]$ ]]
}

# Prompt for free-form input (empty under --safe-all, --pick value when given)
ask() {
    REPLY=""
    if $AUTO_SAFE; then return; fi
    if $PICK_SET; then REPLY=$PICK; echo "$1$REPLY"; log "PICK: $REPLY"; return; fi
    printf "%s" "$1"
    read -r REPLY || true
}

# Run a command — or show it in dry-run mode
run() {
    if $DRY_RUN; then
        echo "${DIM}   [dry-run] would run: $*${RESET}"
        log "DRY: $*"
        return 0
    fi
    log "RUN: $*"
    eval "$@"
}

# Space accounting (in dry-run this is "would free")
TOTAL_FREED_KB=0
account_kb() { TOTAL_FREED_KB=$(( TOTAL_FREED_KB + ${1:-0} )); }

xcode_running() { pgrep -xq Xcode; }

# "Deleted" vs "Would delete" depending on mode
done_verb() { if $DRY_RUN; then echo "Would $1"; else echo "${2:-$1}"; fi; }

# DerivedData folder safe to delete: project gone, or no project info and idle 1+ day
dd_is_safe() {
    [ "${DD_STATUS[$1]}" = stale ] || { [ "${DD_STATUS[$1]}" = nometa ] && [ "${DD_AGE[$1]}" -ge 1 ]; }
}

# Worktree safe to remove: missing record or merged, idle checkout. Never locked or in use.
wt_is_safe() {
    [ "${WT_LOCK[$1]}" != locked ] || return 1
    [ "${WT_STATUS[$1]}" = prunable ] && return 0
    [ "${WT_STATUS[$1]}" = merged ] && [ "${WT_AGE[$1]}" -ge "$WT_IDLE_DAYS" ] && ! wt_in_use "${WT_PATH[$1]}"
}

wt_in_use() {
    command -v lsof >/dev/null 2>&1 || return 0
    [ -s "$TMPD/open-cwds" ] && awk -v p="$1" '$0 == p || index($0, p "/") == 1 { found = 1 } END { exit !found }' "$TMPD/open-cwds"
}

wt_refresh_open_cwds() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n\//\//p' > "$TMPD/open-cwds"
    else
        : > "$TMPD/open-cwds"
    fi
}

path_in_use() {
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -Fn > "$TMPD/all-open-files" 2>/dev/null || return 0
    awk -v p="$1" '
        /^n\// { name = substr($0, 2); if (name == p || index(name, p "/") == 1) found = 1 }
        END { exit !found }' "$TMPD/all-open-files"
}

remove_developer_build() {
    local path="$1" label="$2" before="$3" after
    if $DRY_RUN; then
        info "[dry-run] would delete $label: $path ($(human_kb "$before"))"
        account_kb "$before"
    elif rm -rf -- "$path"; then
        after=$(kb_of "$path")
        account_kb "$(( before - after ))"
        ok "Deleted $label: $path (freed $(human_kb "$(( before - after ))"))"
    else
        err "Could not delete $path"
    fi
}

# Delete a path with before/after measurement and global accounting
remove_path() {
    local label="$1" path="$2" mode="${3:-}"
    if [ ! -e "$path" ]; then
        info "$label: not present, skipping"
        return
    fi
    local before; before=$(kb_of "$path")

    if $DRY_RUN; then
        echo "${DIM}   [dry-run] would delete $label ($(human_kb "$before")): $(tildify "$path")${RESET}"
        log "DRY: rm -rf $path ($(human_kb "$before"))"
        account_kb "$before"
        return
    fi

    # contents-only keeps the parent dir (e.g. DerivedData itself stays)
    if [ "$mode" = "contents-only" ]; then
        run "rm -rf \"$path\"/* \"$path\"/.[!.]* 2>/dev/null"
    else
        run "rm -rf \"$path\""
    fi

    local after; after=$(kb_of "$path")
    local freed=$(( before - after ))
    account_kb "$freed"
    ok "$label: freed $(human_kb "$freed") (was $(human_kb "$before"))"
}

# ── Disk snapshot ──────────────────────────────────────────────────────────
disk_snapshot() {
    header "Disk Status"
    { df -h /System/Volumes/Data 2>/dev/null || df -h /; } | tee -a "$LOG"
}

# ── Data loaders (cached until something is deleted) ───────────────────────

# DerivedData: one row per folder, classified by whether its project still exists
#   live    — project/workspace still on disk
#   stale   — project path no longer exists (deleted worktree/clone) → safe to delete
#   nometa  — no info.plist (interrupted build or tool-created) → usually safe
#   shared  — Xcode-wide caches (ModuleCache, SymbolCache, ...) → regenerate
DD_LOADED=false
load_derived() {
    $DD_LOADED && return 0
    DD_PATH=(); DD_KB=(); DD_STATUS=(); DD_WS=(); DD_AGE=()
    [ -d "$DD_ROOT" ] || { DD_LOADED=true; return 0; }
    local d name ws status
    : > "$TMPD/dd.tsv"
    for d in "$DD_ROOT"/*/; do
        d=${d%/}; name=$(basename "$d")
        ws=""
        case "$name" in
            *.noindex|SDKExplicitPrecompiledModules) status=shared ;;
            *)
                ws=$(plutil -extract WorkspacePath raw -o - "$d/info.plist" 2>/dev/null)
                if [ -z "$ws" ]; then status=nometa
                elif [ -e "$ws" ]; then status=live
                else status=stale
                fi
                ;;
        esac
        printf "%s\t%s\t%s\t%s\t%s\n" "$(kb_of "$d")" "$status" "$(age_days "$d")" "$d" "$ws" >> "$TMPD/dd.tsv"
    done
    local n=0 kb st age p w
    while IFS=$'\t' read -r kb st age p w; do
        DD_KB[n]=$kb; DD_STATUS[n]=$st; DD_AGE[n]=$age; DD_PATH[n]=$p; DD_WS[n]=$w
        n=$((n + 1))
    done < <(sort -t$'\t' -k1,1 -rn "$TMPD/dd.tsv")
    DD_LOADED=true
}

# DeviceSupport: per-OS-version symbol folders from physical devices
DS_LOADED=false
load_devsupport() {
    $DS_LOADED && return 0
    DS_PATH=(); DS_KB=(); DS_AGE=()
    : > "$TMPD/ds.tsv"
    local root v
    for root in "$XCODE_DIR"/*" DeviceSupport"; do
        [ -d "$root" ] || continue
        for v in "$root"/*/; do
            [ -d "$v" ] || continue
            v=${v%/}
            printf "%s\t%s\t%s\n" "$(kb_of "$v")" "$(age_days "$v")" "$v" >> "$TMPD/ds.tsv"
        done
    done
    local n=0 kb age p
    while IFS=$'\t' read -r kb age p; do
        DS_KB[n]=$kb; DS_AGE[n]=$age; DS_PATH[n]=$p
        n=$((n + 1))
    done < <(sort -t$'\t' -k1,1 -rn "$TMPD/ds.tsv")
    DS_LOADED=true
}

# Simulator devices (needs jq + xcrun)
SIM_LOADED=false
load_sims() {
    $SIM_LOADED && return 0
    SIM_UDID=(); SIM_NAME=(); SIM_RT=(); SIM_STATE=(); SIM_AVAIL=(); SIM_KB=(); SIM_AGE=()
    { $HAVE_XCRUN && $HAVE_JQ; } || { SIM_LOADED=true; return 1; }
    xcrun simctl list devices -j > "$TMPD/devs.json" 2>/dev/null || return 1
    : > "$TMPD/sims.tsv"
    local udid name rt state avail dir
    while IFS=$'\t' read -r udid name rt state avail; do
        dir="$SIM_DEVICES/$udid"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$(kb_of "$dir")" "$(age_days "$dir/data" 2>/dev/null)" \
            "$udid" "$name" "$rt" "$state" "$avail" >> "$TMPD/sims.tsv"
    done < <(jq -r '.devices | to_entries[] | .key as $rt | .value[] |
        [.udid, .name,
         ($rt | sub("com.apple.CoreSimulator.SimRuntime."; "") | sub("-"; " ") | gsub("-"; ".")),
         .state, (.isAvailable | tostring)] | @tsv' "$TMPD/devs.json")
    local n=0 kb age
    while IFS=$'\t' read -r kb age udid name rt state avail; do
        SIM_KB[n]=$kb; SIM_AGE[n]=$age; SIM_UDID[n]=$udid; SIM_NAME[n]=$name
        SIM_RT[n]=$rt; SIM_STATE[n]=$state; SIM_AVAIL[n]=$avail
        n=$((n + 1))
    done < <(sort -t$'\t' -k1,1 -rn "$TMPD/sims.tsv")
    SIM_LOADED=true
}

# Simulator runtimes (system-wide disk images) + their dyld shared caches
RT_LOADED=false
load_runtimes() {
    $RT_LOADED && return 0
    RT_ID=(); RT_PLAT=(); RT_VER=(); RT_BUILD=(); RT_BYTES=(); RT_USED=(); RT_RID=()
    RT_DEVS=(); RT_CACHE_DIR=(); RT_CACHE_KB=()
    { $HAVE_XCRUN && $HAVE_JQ; } || { RT_LOADED=true; return 1; }
    xcrun simctl list devices -j > "$TMPD/devs.json" 2>/dev/null || return 1
    xcrun simctl runtime list -j 2>/dev/null | jq -r '
        def plat: {"com.apple.platform.iphonesimulator":"iOS",
                   "com.apple.platform.watchsimulator":"watchOS",
                   "com.apple.platform.xrsimulator":"visionOS",
                   "com.apple.platform.appletvsimulator":"tvOS"}[.] // .;
        [.[]] | sort_by(.platformIdentifier, (.version | split(".") | map(tonumber? // 0)))
        | .[] | [.identifier, (.platformIdentifier | plat), .version, .build,
                 ((.sizeBytes // 0) | tostring), ((.lastUsedAt // "never")[0:10]),
                 .runtimeIdentifier] | @tsv' > "$TMPD/rt.tsv" || return 1
    local n=0 id plat ver build bytes used rid c cdir
    while IFS=$'\t' read -r id plat ver build bytes used rid; do
        RT_ID[n]=$id; RT_PLAT[n]=$plat; RT_VER[n]=$ver; RT_BUILD[n]=$build
        RT_BYTES[n]=$bytes; RT_USED[n]=$used; RT_RID[n]=$rid
        RT_DEVS[n]=$(jq -r --arg r "$rid" '(.devices[$r] // []) | length' "$TMPD/devs.json")
        cdir=""
        for c in "$DYLD_ROOT"/*/"$rid.$build"; do [ -d "$c" ] && cdir="$c"; done
        RT_CACHE_DIR[n]=$cdir
        if [ -n "$cdir" ]; then RT_CACHE_KB[n]=$(kb_of "$cdir"); else RT_CACHE_KB[n]=0; fi
        n=$((n + 1))
    done < "$TMPD/rt.tsv"
    RT_LOADED=true
}

# Linked git worktrees of every repo under ~ (main checkouts are skipped), classified:
#   prunable — directory is gone, only git's unlocked record remains
#   locked-missing — directory is gone but Git intentionally preserves its record
#   leftover — unregistered directory inside a repo's worktree folder
#   merged   — HEAD is in the default branch, or (via gh) a merged PR's head is exactly HEAD
#   dirty    — uncommitted/untracked files → removable only after saving them to WT_BACKUP_DIR
#   orphan   — detached HEAD whose commits no branch holds → removing would lose them
#   idle     — clean, work is on a branch; may still be in use
# Merge detection uses local refs: `git fetch --prune` in a repo makes it sharper.
WT_LOADED=false
load_worktrees() {
    $WT_LOADED && return 0
    WT_REPO=(); WT_PATH=(); WT_BRANCH=(); WT_SHA=(); WT_BASE=(); WT_STATUS=(); WT_LOCK=(); WT_KB=(); WT_AGE=(); WT_VIA=()
    command -v git >/dev/null 2>&1 || { WT_LOADED=true; return 0; }
    : > "$TMPD/wt.tsv"
    local repo base b wt sha br lock prun st kb age gd parent via prs
    while IFS= read -r repo; do
        # squash/rebase merges never make HEAD an ancestor of main; ask GitHub which PR heads merged
        prs="$TMPD/prs.$(echo "$repo" | cksum | cut -d' ' -f1)"
        : > "$prs"
        if command -v gh >/dev/null 2>&1 && git -C "$repo" remote get-url origin 2>/dev/null | grep -q github.com; then
            (cd "$repo" && gh pr list --state merged --limit 2000 --json headRefName,headRefOid \
                --jq '.[] | [.headRefName, .headRefOid] | @tsv' > "$prs" 2>/dev/null) || : > "$prs"
        fi
        base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
        if [ -z "$base" ]; then
            for b in origin/main origin/master main master; do
                git -C "$repo" rev-parse -q --verify "$b" >/dev/null 2>&1 && { base=$b; break; }
            done
        fi
        while IFS=$'\t' read -r wt sha br lock prun; do
            kb=0; age=0; via=-
            if [ ! -d "$wt" ]; then
                if [ "$lock" = locked ]; then st=locked-missing; else st=prunable; fi
            elif [ "$prun" != "-" ]; then
                st=invalid
            else
                gd=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)
                age=$(age_days "$gd/index")   # read before `status`, which can touch the index
                kb=$(kb_of "$wt")
                if [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$wt" status --porcelain 2>/dev/null | head -1)" ]; then
                    st=dirty
                elif [ -n "$base" ] && git -C "$repo" merge-base --is-ancestor "$sha" "$base" 2>/dev/null; then
                    st=merged; via=ancestor
                elif [ "$br" != - ] && awk -F'\t' -v b="$br" -v s="$sha" '$1 == b && $2 == s { f = 1 } END { exit !f }' "$prs"; then
                    st=merged; via=pr
                elif [ -z "$(git -C "$repo" for-each-ref --contains "$sha" --count=1 --format=x 2>/dev/null)" ]; then
                    st=orphan
                else
                    st=idle
                fi
            fi
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$kb" "$st" "$age" "$lock" "$repo" "$wt" "$br" "$sha" "$base" "$via" >> "$TMPD/wt.tsv"
        done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | awk -v RS= -F'\n' '
            NR > 1 { p = h = b = ""; l = u = "-"
                for (i = 1; i <= NF; i++) {
                    if      ($i ~ /^worktree /) p = substr($i, 10)
                    else if ($i ~ /^HEAD /)     h = substr($i, 6)
                    else if ($i ~ /^branch /)   b = substr($i, 19)
                    else if ($i ~ /^locked/)    l = "locked"
                    else if ($i ~ /^prunable/)  u = "prunable" }
                if (b == "") b = "-"
                printf "%s\t%s\t%s\t%s\t%s\n", p, h, b, l, u }')
        for parent in "$repo/.worktrees" "$repo/.claude/worktrees"; do
            [ -d "$parent" ] || continue
            for wt in "$parent"/*; do
                [ -d "$wt" ] && [ ! -L "$wt" ] && [ ! -e "$wt/.git" ] || continue
                kb=$(kb_of "$wt"); age=$(age_days "$wt")
                printf "%s\tleftover\t%s\t-\t%s\t%s\t-\t-\t%s\t-\n" "$kb" "$age" "$repo" "$wt" "$base" >> "$TMPD/wt.tsv"
            done
        done
    done < <(find "$HOME" -maxdepth "$WT_DEPTH" \( -name Library -o -name node_modules -o -name .Trash \
                 -o -name Pods -o -name worktrees -o -name .worktrees \) -prune \
                 -o -name .git -type d -print -prune 2>/dev/null | sed 's|/\.git$||')
    local n=0
    while IFS=$'\t' read -r kb st age lock repo wt br sha base via; do
        WT_KB[n]=$kb; WT_STATUS[n]=$st; WT_AGE[n]=$age; WT_LOCK[n]=$lock
        WT_REPO[n]=$repo; WT_PATH[n]=$wt; WT_BRANCH[n]=$br; WT_SHA[n]=$sha; WT_BASE[n]=$base; WT_VIA[n]=$via
        n=$((n + 1))
    done < <(sort -t$'\t' -k1,1 -rn "$TMPD/wt.tsv")
    WT_LOADED=true
}

# dyld cache dirs whose runtime is no longer installed
find_orphan_dyld() {
    ORPHAN_DYLD=()
    [ -d "$DYLD_ROOT" ] || return 0
    load_runtimes
    local c base i found
    for c in "$DYLD_ROOT"/*/com.apple.CoreSimulator.SimRuntime.*; do
        [ -d "$c" ] || continue
        base=$(basename "$c"); found=false
        for ((i = 0; i < ${#RT_ID[@]}; i++)); do
            [ "$base" = "${RT_RID[i]}.${RT_BUILD[i]}" ] && { found=true; break; }
        done
        $found || ORPHAN_DYLD[${#ORPHAN_DYLD[@]}]="$c"
    done
}

invalidate_all() { DD_LOADED=false; DS_LOADED=false; SIM_LOADED=false; RT_LOADED=false; WT_LOADED=false; }

# ── Insights report ────────────────────────────────────────────────────────
INS_SAFE_KB=""; INS_DD_KB=""; INS_DD_STALE_KB=""; INS_DS_KB=""; INS_DS_OLD_KB=""
INS_SIM_KB=""; INS_RT_KB=""; INS_RT_NEVER_KB=""; INS_LC_KB=""; INS_DC_KB=""
INS_WT_KB=""; INS_WT_SAFE_KB=""
INS_MCP_KB=""; INS_TEMP_KB=""; INS_AGENT_CACHE_KB=""

safe_cache_paths() {
    local p
    for p in "$HOME/.npm" "$HOME/Library/pnpm/store" "$HOME/Library/Caches/pnpm" \
             "$HOME/Library/Caches/org.swift.swiftpm" "$HOME/Library/Caches/com.apple.dt.Xcode" \
             "$HOME/Library/Caches/Homebrew" "$HOME/Library/Caches/pip" "$HOME/.cache/uv" \
             "$HOME/Library/Caches/Yarn" "$HOME/.cache/bazel"; do
        [ -e "$p" ] && echo "$p"
    done
}

developer_storage_report() {
    header "Developer storage (read-only)"
    info "These rows can overlap worktrees and caches elsewhere in the report; do not add them together."
    local path label kb ws tp dd temp_root="$TEMP_ROOT"
    row "${BOLD}  Size      Category                  Location${RESET}"
    while IFS=$'\t' read -r label path; do
        kb=$(kb_of "$path")
        [ "$kb" -gt 0 ] && row "$(printf '  %-8s  %-24s  %s' "$(human_kb "$kb")" "$label" "$(tildify "$path")")"
    done <<EOF
XcodeBuildMCP	$HOME/Library/Developer/XcodeBuildMCP
Codex state	$HOME/.codex
Claude CLI state	$HOME/.claude
Claude desktop data	$HOME/Library/Application Support/Claude
App caches	$HOME/Library/Caches
CLI caches	$HOME/.cache
Temporary files	$temp_root
EOF
    if [ -n "${TMPDIR:-}" ] && [ "$TMPDIR" != "$temp_root" ]; then
        kb=$(kb_of "$TMPDIR")
        [ "$kb" -gt 0 ] && row "$(printf '  %-8s  %-24s  %s' "$(human_kb "$kb")" "Session temp files" "$TMPDIR")"
    fi

    header "Agent data detail"
    info "Session histories and VM bundles are application state; review them before any cleanup."
    while IFS='|' read -r label path; do
        kb=$(kb_of "$path")
        [ "$kb" -gt 0 ] && row "$(printf '  %-8s  %-24s  %s' "$(human_kb "$kb")" "$label" "$(tildify "$path")")"
    done <<EOF
Codex sessions|$HOME/.codex/sessions
Codex plugins|$HOME/.codex/plugins
Claude projects|$HOME/.claude/projects
Claude VM bundle|$HOME/Library/Application Support/Claude/vm_bundles
Claude desktop cache|$HOME/Library/Application Support/Claude/Cache
EOF

    header "Largest user cache entries"
    : > "$TMPD/user-cache-entries.tsv"
    du -xsk "$HOME/Library/Caches"/* "$HOME/.cache"/* 2>/dev/null | sort -rn | head -10 > "$TMPD/user-cache-entries.tsv"
    while IFS=$'\t' read -r kb path; do
        row "$(printf '  %-8s  %s' "$(human_kb "$kb")" "$(tildify "$path")")"
    done < "$TMPD/user-cache-entries.tsv"

    header "XcodeBuildMCP workspaces"
    info "Build products can be recreated; workspace logs, results, and state may be useful. Nothing is deleted here."
    : > "$TMPD/mcp-workspaces.tsv"
    for ws in "$HOME/Library/Developer/XcodeBuildMCP/workspaces"/*; do
        [ -d "$ws" ] || continue
        kb=$(kb_of "$ws")
        [ "$kb" -gt 1024 ] || continue
        tp=$(kb_of "$ws/test-products")
        dd=$(kb_of "$ws/DerivedData")
        printf '%s\t%s\t%s\t%s\n' "$kb" "$tp" "$dd" "$(basename "$ws")" >> "$TMPD/mcp-workspaces.tsv"
    done
    row "${BOLD}  Total     Test products  DerivedData  Workspace${RESET}"
    while IFS=$'\t' read -r kb tp dd label; do
        row "$(printf '  %-8s  %-13s  %-11s  %s' "$(human_kb "$kb")" "$(human_kb "$tp")" "$(human_kb "$dd")" "$label")"
    done < <(sort -t$'\t' -k1,1 -rn "$TMPD/mcp-workspaces.tsv" | head -12)

    header "Largest temporary entries"
    info "Temporary paths are inspection only; active tools may be using them."
    du -xsk "$temp_root"/* 2>/dev/null | sort -rn | head -10 > "$TMPD/temp-entries.tsv"
    while IFS=$'\t' read -r kb path; do
        row "$(printf '  %-8s  %s' "$(human_kb "$kb")" "$path")"
    done < "$TMPD/temp-entries.tsv"
}

clean_mcp_builds() {
    header "XcodeBuildMCP build outputs"
    local root="$HOME/Library/Developer/XcodeBuildMCP/workspaces" ws kind path kb age i=0 sel idx
    local paths=() workspaces=() kinds=() sizes=()
    [ -d "$root" ] || { info "No XcodeBuildMCP workspaces found"; return; }
    for ws in "$root"/*; do
        [ -d "$ws" ] && [ ! -L "$ws" ] || continue
        for kind in test-products DerivedData; do
            path="$ws/$kind"
            [ -d "$path" ] && [ ! -L "$path" ] || continue
            kb=$(kb_of "$path")
            [ "$kb" -gt 0 ] || continue
            paths[i]=$path; workspaces[i]=$ws; kinds[i]=$kind; sizes[i]=$kb
            i=$((i + 1))
        done
    done
    [ "$i" -gt 0 ] || { info "No build outputs found"; return; }
    row "${BOLD}   #  Size      Age   Workspace / output${RESET}"
    for ((idx = 0; idx < i; idx++)); do
        age=$(age_days "${paths[idx]}")
        row "$(printf '  %2d) %-8s %4sd  %s / %s' $((idx + 1)) "$(human_kb "${sizes[idx]}")" "$age" "$(basename "${workspaces[idx]}")" "${kinds[idx]}")"
    done
    info "Only build outputs are listed. Workspace state, logs, and test results remain in place."
    echo
    echo "  ${BOLD}1 3 5-7${RESET}) pick   ${BOLD}enter${RESET}) skip"
    ask "> "
    [ -n "$REPLY" ] || { info "Skipped"; return; }
    case " $REPLY " in *" all "*) warn "Pick numbered entries"; return ;; esac
    sel=$(parse_selection "$REPLY" "$i")
    [ -n "$sel" ] || { info "Nothing selected"; return; }
    confirm "Delete the selected XcodeBuildMCP build outputs?" || return
    for idx in $sel; do
        idx=$((idx - 1)); path=${paths[idx]}; ws=${workspaces[idx]}; kind=${kinds[idx]}
        if [ "$(dirname "$ws")" != "$root" ] || [ "$(dirname "$path")" != "$ws" ] ||
           [ "$(basename "$path")" != "$kind" ] || [ ! -d "$path" ] || [ -L "$path" ] ||
           [ -L "$ws" ] || path_in_use "$path"; then
            warn "$path changed or is in use; skipping"
            continue
        fi
        if [ -n "$(find "$path" -mmin -120 -print -quit 2>/dev/null)" ]; then
            warn "$path contains files touched in the last two hours."
            confirm "Delete this recently used output?" || continue
        fi
        remove_developer_build "$path" "$kind" "$(kb_of "$path")"
    done
}

is_xcode_build_dir() {
    [ -d "$1/Build" ] && { [ -d "$1/SourcePackages" ] || [ -d "$1/Index.noindex" ] ||
        [ -d "$1/ModuleCache.noindex" ] || [ -d "$1/SDKStatCaches.noindex" ]; }
}

temp_build_candidate() {
    local path="$1" root="$2" kb
    [ -d "$path" ] && [ ! -L "$path" ] && is_xcode_build_dir "$path" &&
        [ ! -e "$path/.git" ] || return
    kb=$(kb_of "$path")
    [ "$kb" -gt 0 ] || return
    TB_PATH[${#TB_PATH[@]}]=$path
    TB_ROOT[${#TB_ROOT[@]}]=$root
    TB_KB[${#TB_KB[@]}]=$kb
}

load_temp_builds() {
    local root path raw seen="" agent="claude-$(id -u)"
    TB_PATH=(); TB_ROOT=(); TB_KB=()
    for raw in "$TEMP_ROOT" "${TMPDIR:-}"; do
        [ -d "$raw" ] || continue
        root=$(cd "$raw" && pwd -P)
        [ "$root" != / ] || continue
        case " $seen " in *" $root "*) continue ;; esac
        seen="$seen $root"
        for path in "$root"/* "$root/$agent"/* "$root/$agent"/*/*/scratchpad/* "$root/$agent"/*/*/scratchpad/*/*; do
            temp_build_candidate "$path" "$root"
        done
    done
}

clean_temp_builds() {
    header "Temporary Xcode build directories"
    local root path i idx sel age
    load_temp_builds
    [ "${#TB_PATH[@]}" -gt 0 ] || { info "No temporary Xcode build directories found"; return; }
    row "${BOLD}   #  Size      Age   Directory${RESET}"
    for ((i = 0; i < ${#TB_PATH[@]}; i++)); do
        age=$(age_days "${TB_PATH[i]}")
        row "$(printf '  %2d) %-8s %4sd  %s' $((i + 1)) "$(human_kb "${TB_KB[i]}")" "$age" "${TB_PATH[i]}")"
    done
    info "Only directories with Xcode build markers are listed; other scratchpad files remain."
    echo
    echo "  ${BOLD}1 3 5-7${RESET}) pick   ${BOLD}enter${RESET}) skip"
    ask "> "
    [ -n "$REPLY" ] || { info "Skipped"; return; }
    case " $REPLY " in *" all "*) warn "Pick numbered entries"; return ;; esac
    sel=$(parse_selection "$REPLY" "${#TB_PATH[@]}")
    [ -n "$sel" ] || { info "Nothing selected"; return; }
    confirm "Delete the selected temporary Xcode build directories?" || return
    for idx in $sel; do
        idx=$((idx - 1)); path=${TB_PATH[idx]}; root=${TB_ROOT[idx]}
        if [ ! -d "$path" ] || [ -L "$path" ] || [ -e "$path/.git" ] || ! is_xcode_build_dir "$path" ||
           [ "$(cd "$path" && pwd -P)" != "$path" ] || path_in_use "$path"; then
            warn "$path changed or is in use; skipping"
            continue
        fi
        case "$path" in "$root"/*) ;; *) warn "$path is outside the temp root; skipping"; continue ;; esac
        if [ -n "$(find "$path" -mmin -120 -print -quit 2>/dev/null)" ]; then
            warn "$path contains files touched in the last two hours."
            confirm "Delete this recently used build directory?" || continue
        fi
        remove_developer_build "$path" "temporary build" "$(kb_of "$path")"
    done
}

agent_cache_paths() {
    cat <<EOF
Claude desktop cache|$HOME/Library/Application Support/Claude/Cache
Claude code cache|$HOME/Library/Application Support/Claude/Code Cache
Claude GPU cache|$HOME/Library/Application Support/Claude/GPUCache
Claude CLI cache|$HOME/.claude/cache
Codex CLI cache|$HOME/.codex/cache
Codex app cache|$HOME/Library/Caches/Codex
Claude CLI logs cache|$HOME/Library/Caches/claude-cli-nodejs
EOF
}

clean_agent_caches() {
    header "Agent application caches"
    local path label kb i=0 idx sel
    local paths=() labels=() sizes=()
    while IFS='|' read -r label path; do
        [ -d "$path" ] && [ ! -L "$path" ] || continue
        kb=$(kb_of "$path")
        [ "$kb" -gt 0 ] || continue
        paths[i]=$path; labels[i]=$label; sizes[i]=$kb
        i=$((i + 1))
    done < <(agent_cache_paths)
    [ "$i" -gt 0 ] || { info "No agent caches found"; return; }
    row "${BOLD}   #  Size      Cache${RESET}"
    for ((idx = 0; idx < i; idx++)); do
        row "$(printf '  %2d) %-8s  %s → %s' $((idx + 1)) "$(human_kb "${sizes[idx]}")" "${labels[idx]}" "$(tildify "${paths[idx]}")")"
    done
    info "Quit the related app before deleting its cache. Sessions, plugins, and VM bundles are not listed."
    echo
    echo "  ${BOLD}1 3 5-7${RESET}) pick   ${BOLD}enter${RESET}) skip"
    ask "> "
    [ -n "$REPLY" ] || { info "Skipped"; return; }
    case " $REPLY " in *" all "*) warn "Pick numbered entries"; return ;; esac
    sel=$(parse_selection "$REPLY" "$i")
    [ -n "$sel" ] || { info "Nothing selected"; return; }
    confirm "Delete the selected agent caches?" || return
    for idx in $sel; do
        idx=$((idx - 1)); path=${paths[idx]}
        if [ ! -d "$path" ] || [ -L "$path" ] || path_in_use "$path"; then
            warn "$path changed or is in use; skipping"
            continue
        fi
        case "$path" in
            "$HOME/Library/Application Support/Claude/"*)
                if pgrep -xq Claude; then warn "Claude is running; skipping $path"; continue; fi ;;
            "$HOME/Library/Caches/Codex"|"$HOME/.codex/cache")
                if pgrep -xq Codex; then warn "Codex is running; skipping $path"; continue; fi ;;
        esac
        remove_developer_build "$path" "agent cache" "$(kb_of "$path")"
    done
}

insights() {
    header "Where your space is going"
    echo "${DIM}Scanning DerivedData, worktrees, simulators and runtimes — this can take a minute or two...${RESET}"
    invalidate_all
    load_derived; load_devsupport; load_sims; load_runtimes; load_worktrees

    local wt_total=0 wt_safe=0 wt_safe_n=0
    wt_refresh_open_cwds
    for ((i = 0; i < ${#WT_PATH[@]}; i++)); do
        wt_total=$(( wt_total + WT_KB[i] ))
        if wt_is_safe "$i"; then wt_safe=$(( wt_safe + WT_KB[i] )); wt_safe_n=$(( wt_safe_n + 1 )); fi
    done

    local i kb dd_total=0 dd_stale=0 dd_stale_n=0 ds_total=0 ds_old=0 ds_old_n=0
    for ((i = 0; i < ${#DD_PATH[@]}; i++)); do
        dd_total=$(( dd_total + DD_KB[i] ))
        if dd_is_safe "$i"; then
            dd_stale=$(( dd_stale + DD_KB[i] )); dd_stale_n=$(( dd_stale_n + 1 ))
        fi
    done
    for ((i = 0; i < ${#DS_PATH[@]}; i++)); do
        ds_total=$(( ds_total + DS_KB[i] ))
        if [ "${DS_AGE[i]}" -ge "$OLD_DAYS" ]; then
            ds_old=$(( ds_old + DS_KB[i] )); ds_old_n=$(( ds_old_n + 1 ))
        fi
    done

    local sim_total=0 sim_unavail=0 sim_unavail_n=0 sim_big_n=0 sim_big=0
    for ((i = 0; i < ${#SIM_UDID[@]}; i++)); do
        sim_total=$(( sim_total + SIM_KB[i] ))
        if [ "${SIM_AVAIL[i]}" != true ]; then
            sim_unavail=$(( sim_unavail + SIM_KB[i] )); sim_unavail_n=$(( sim_unavail_n + 1 ))
        elif [ "${SIM_STATE[i]}" = Shutdown ] && [ "${SIM_KB[i]}" -ge 5242880 ]; then
            sim_big=$(( sim_big + SIM_KB[i] )); sim_big_n=$(( sim_big_n + 1 ))
        fi
    done

    local rt_total=0 rt_cache=0 rt_never=0 rt_never_n=0
    for ((i = 0; i < ${#RT_ID[@]}; i++)); do
        kb=$(( RT_BYTES[i] / 1024 ))
        rt_total=$(( rt_total + kb )); rt_cache=$(( rt_cache + RT_CACHE_KB[i] ))
        if [ "${RT_USED[i]}" = never ] && [ "${RT_DEVS[i]}" -eq 0 ]; then
            rt_never=$(( rt_never + kb + RT_CACHE_KB[i] )); rt_never_n=$(( rt_never_n + 1 ))
        fi
    done
    find_orphan_dyld
    local orphan_kb=0 c
    for ((i = 0; i < ${#ORPHAN_DYLD[@]}; i++)); do
        orphan_kb=$(( orphan_kb + $(kb_of "${ORPHAN_DYLD[i]}") ))
    done

    local safe_kb=0 p
    while IFS= read -r p; do safe_kb=$(( safe_kb + $(kb_of "$p") )); done < <(safe_cache_paths)

    local tb_kb=0
    load_temp_builds
    for ((i = 0; i < ${#TB_KB[@]}; i++)); do tb_kb=$(( tb_kb + TB_KB[i] )); done

    local lc_kb dc_kb logs_kb android_kb docker_kb mcp_kb codex_kb claude_kb claude_app_kb temp_kb user_temp_kb=0
    lc_kb=$(kb_of "$HOME/Library/Caches")
    dc_kb=$(kb_of "$HOME/.cache")
    logs_kb=$(kb_of "$HOME/Library/Logs")
    android_kb=$(kb_of "$HOME/Library/Android")
    docker_kb=$(kb_of "$HOME/Library/Containers/com.docker.docker")
    mcp_kb=$(kb_of "$HOME/Library/Developer/XcodeBuildMCP")
    codex_kb=$(kb_of "$HOME/.codex")
    claude_kb=$(kb_of "$HOME/.claude")
    claude_app_kb=$(kb_of "$HOME/Library/Application Support/Claude")
    temp_kb=$(kb_of "$TEMP_ROOT")
    if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
        local primary_temp secondary_temp
        primary_temp=$(cd "$TEMP_ROOT" 2>/dev/null && pwd -P)
        secondary_temp=$(cd "$TMPDIR" && pwd -P)
        case "$secondary_temp" in
            "$primary_temp"|"$primary_temp"/*) ;;
            *) user_temp_kb=$(kb_of "$TMPDIR") ;;
        esac
    fi
    local agent_cache_kb=0 cache_label cache_path
    while IFS='|' read -r cache_label cache_path; do
        agent_cache_kb=$(( agent_cache_kb + $(kb_of "$cache_path") ))
    done < <(agent_cache_paths)

    # Breakdown table, largest first
    {
        printf "%s\t%s\t%s\n" "$rt_total"   "Simulator runtimes (${#RT_ID[@]} installed)" "/System/Library/AssetsV2 (via simctl)"
        printf "%s\t%s\t%s\n" "$dd_total"   "Xcode DerivedData (${#DD_PATH[@]} folders)"   "$(tildify "$DD_ROOT")"
        printf "%s\t%s\t%s\n" "$wt_total"   "Git worktrees (${#WT_PATH[@]})"                "linked worktrees of repos under ~"
        printf "%s\t%s\t%s\n" "$sim_total"  "Simulator devices (${#SIM_UDID[@]})"          "$(tildify "$SIM_DEVICES")"
        printf "%s\t%s\t%s\n" "$rt_cache"   "Simulator dyld caches"                         "$DYLD_ROOT"
        printf "%s\t%s\t%s\n" "$ds_total"   "Device support files"                          "~/Library/Developer/Xcode/* DeviceSupport"
        printf "%s\t%s\t%s\n" "$lc_kb"      "App caches"                                    "~/Library/Caches"
        printf "%s\t%s\t%s\n" "$dc_kb"      "CLI caches"                                    "~/.cache"
        printf "%s\t%s\t%s\n" "$(kb_of "$HOME/.npm")" "npm cache"                          "~/.npm"
        printf "%s\t%s\t%s\n" "$logs_kb"    "Logs"                                          "~/Library/Logs"
        printf "%s\t%s\t%s\n" "$docker_kb"  "Docker"                                        "~/Library/Containers/com.docker.docker"
        printf "%s\t%s\t%s\n" "$android_kb" "Android SDK"                                   "~/Library/Android"
        printf "%s\t%s\t%s\n" "$mcp_kb" "XcodeBuildMCP workspaces"                      "~/Library/Developer/XcodeBuildMCP"
        printf "%s\t%s\t%s\n" "$codex_kb" "Codex state and sessions"                       "~/.codex"
        printf "%s\t%s\t%s\n" "$claude_kb" "Claude CLI state"                            "~/.claude"
        printf "%s\t%s\t%s\n" "$claude_app_kb" "Claude desktop data"                    "~/Library/Application Support/Claude"
        printf "%s\t%s\t%s\n" "$temp_kb" "Temporary files"                            "$TEMP_ROOT"
        printf "%s\t%s\t%s\n" "$user_temp_kb" "Session temporary files"                  "${TMPDIR:-}"
    } | sort -t$'\t' -k1,1 -rn > "$TMPD/breakdown.tsv"

    echo
    row "${BOLD}  Size      Category                          Location${RESET}"
    local label loc
    while IFS=$'\t' read -r kb label loc; do
        [ "$kb" -gt 0 ] || continue
        row "$(printf "  %-8s  %-32s  ${DIM}%s${RESET}" "$(human_kb "$kb")" "$label" "$loc")"
    done < "$TMPD/breakdown.tsv"
    info "Rows can overlap (for example, Codex state includes worktrees). Use --developer-storage for MCP and temp details."

    # Recommendations
    header "What you can reclaim"
    local any=false
    rec() { any=true; row "$(printf "  ${GREEN}%-8s${RESET} %s ${DIM}→ menu %s${RESET}" "$(human_kb "$1")" "$2" "$3")"; }
    [ "$safe_kb" -gt 0 ]      && rec "$safe_kb"    "Package manager caches (npm, pnpm, SwiftPM, brew, pip, uv) — zero risk" "1"
    [ "$wt_safe_n" -gt 0 ]    && rec "$wt_safe"    "$wt_safe_n git worktrees merged or missing (idle ${WT_IDLE_DAYS}+ days) — do this before DerivedData" "w"
    [ "$dd_stale_n" -gt 0 ]   && rec "$dd_stale"   "$dd_stale_n DerivedData folders for deleted/unknown projects — zero risk" "2"
    [ "$tb_kb" -gt 0 ]        && rec "$tb_kb"      "${#TB_PATH[@]} temporary Xcode build folders (agent scratchpads, /tmp) — rebuildable" "13"
    [ "$rt_never_n" -gt 0 ]   && rec "$rt_never"   "$rt_never_n simulator runtimes never used and with no simulators (incl. dyld caches)" "4"
    [ "$orphan_kb" -gt 0 ]    && rec "$orphan_kb"  "${#ORPHAN_DYLD[@]} dyld caches left behind by deleted runtimes" "4"
    [ "$sim_unavail_n" -gt 0 ] && rec "$sim_unavail" "$sim_unavail_n unavailable simulators (runtime gone) — zero risk" "5"
    [ "$sim_big_n" -gt 0 ]    && rec "$sim_big"    "$sim_big_n shut-down simulators over 5G (erase or delete to reclaim)" "5"
    [ "$ds_old_n" -gt 0 ]     && rec "$ds_old"     "$ds_old_n DeviceSupport folders untouched for ${OLD_DAYS}+ days" "3"
    $any || info "Nothing obvious to reclaim."

    # Extra observations
    local live_wt=0 live_wt_kb=0
    for ((i = 0; i < ${#DD_PATH[@]}; i++)); do
        if [ "${DD_STATUS[i]}" = live ] && [[ "${DD_WS[i]}" == *worktree* ]]; then
            live_wt=$(( live_wt + 1 )); live_wt_kb=$(( live_wt_kb + DD_KB[i] ))
        fi
    done
    if [ "$live_wt" -gt 0 ]; then
        echo
        info "Note: $live_wt DerivedData folders ($(human_kb "$live_wt_kb")) belong to git worktrees that still exist."
        info "      Remove finished worktrees (menu w) and they become 'stale' here."
    fi
    $HAVE_JQ || warn "jq not found — simulator/runtime insights are limited (brew install jq)."

    INS_SAFE_KB=$safe_kb; INS_DD_KB=$dd_total; INS_DD_STALE_KB=$dd_stale
    INS_DS_KB=$ds_total; INS_DS_OLD_KB=$ds_old; INS_SIM_KB=$sim_total
    INS_RT_KB=$(( rt_total + rt_cache )); INS_RT_NEVER_KB=$(( rt_never + orphan_kb ))
    INS_LC_KB=$lc_kb; INS_DC_KB=$dc_kb
    INS_WT_KB=$wt_total; INS_WT_SAFE_KB=$wt_safe
    INS_MCP_KB=$mcp_kb; INS_TEMP_KB=$(( temp_kb + user_temp_kb )); INS_AGENT_CACHE_KB=$agent_cache_kb
}

# ── Cleanup actions ────────────────────────────────────────────────────────

# 1. ZERO-RISK: package manager caches, regenerate on demand
clean_safe_caches() {
    header "Safe Cache Cleanup (zero risk, regenerates on demand)"

    if command -v brew >/dev/null 2>&1; then
        info "Homebrew cleanup..."
        run "brew cleanup -s --prune=all >/dev/null 2>&1 || true"
        local brew_cache; brew_cache=$(brew --cache 2>/dev/null)
        [ -n "$brew_cache" ] && [ -d "$brew_cache" ] && remove_path "Homebrew cache" "$brew_cache" contents-only
    fi

    if command -v npm >/dev/null 2>&1; then
        run "npm cache clean --force >/dev/null 2>&1 || true"
    fi
    remove_path "~/.npm" "$HOME/.npm" contents-only

    if command -v pnpm >/dev/null 2>&1; then
        run "pnpm store prune >/dev/null 2>&1 || true"
    fi
    remove_path "pnpm store" "$HOME/Library/pnpm/store" contents-only
    remove_path "pnpm cache" "$HOME/Library/Caches/pnpm" contents-only

    command -v yarn >/dev/null 2>&1 && run "yarn cache clean >/dev/null 2>&1 || true"
    command -v pip3 >/dev/null 2>&1 && run "pip3 cache purge >/dev/null 2>&1 || true"
    command -v uv   >/dev/null 2>&1 && run "uv cache clean >/dev/null 2>&1 || true"
    if command -v poetry >/dev/null 2>&1; then
        run 'for c in $(poetry cache list 2>/dev/null); do poetry cache clear "$c" --all -n >/dev/null 2>&1; done'
    fi

    remove_path "SwiftPM cache" "$HOME/Library/Caches/org.swift.swiftpm" contents-only
    remove_path "Xcode caches"  "$HOME/Library/Caches/com.apple.dt.Xcode" contents-only
    remove_path "Bazel cache"   "$HOME/.cache/bazel" contents-only

    ok "Safe cache cleanup complete"
}

# 2. DERIVEDDATA: per-project, flags folders whose project is gone
#    $1 = "auto" → pre-select stale + no-metadata folders
clean_derived_data() {
    header "Xcode DerivedData ($(tildify "$DD_ROOT"))"
    load_derived
    local n=${#DD_PATH[@]} i st color total=0
    if [ "$n" -eq 0 ]; then info "Empty"; return; fi

    row "${BOLD}   #  Status   Size     Age   Folder → project${RESET}"
    for ((i = 0; i < n; i++)); do
        st=${DD_STATUS[i]}
        case "$st" in
            live)   color=$GREEN ;;
            stale)  color=$RED ;;
            nometa) color=$YELLOW ;;
            *)      color=$DIM ;;
        esac
        total=$(( total + DD_KB[i] ))
        row "$(printf "  %2d) ${color}%-7s${RESET}  %-7s %4sd  %s ${DIM}%s${RESET}" \
            $((i + 1)) "$st" "$(human_kb "${DD_KB[i]}")" "${DD_AGE[i]}" \
            "$(basename "${DD_PATH[i]}" | cut -c1-28)" "${DD_WS[i]:+→ $(tildify "${DD_WS[i]}")}")"
    done
    info "Total: $(human_kb "$total")"
    info "${RED}stale${RESET}${DIM} = project path gone (safe) · ${YELLOW}nometa${RESET}${DIM} = no project info (safe once idle 1d+) · shared = Xcode-wide caches"

    local sel=""
    if [ "${1:-}" = auto ]; then
        REPLY=s
    else
        echo
        echo "  ${BOLD}s${RESET}) safe ones (stale + idle nometa)   ${BOLD}1 3 5-7${RESET}) pick   ${BOLD}all${RESET}) everything   ${BOLD}enter${RESET}) skip"
        ask "> "
    fi
    case "$REPLY" in
        "") info "Skipped"; return ;;
        s)
            for ((i = 0; i < n; i++)); do
                dd_is_safe "$i" && sel="$sel $((i + 1))"
            done
            ;;
        *) sel=$(parse_selection "$REPLY" "$n") ;;
    esac
    if [ -z "$(echo $sel)" ]; then info "Nothing selected"; return; fi

    local sel_kb=0 live_sel=false idx
    for idx in $sel; do
        sel_kb=$(( sel_kb + DD_KB[idx - 1] ))
        dd_is_safe $((idx - 1)) || live_sel=true
    done
    if $live_sel && xcode_running; then
        warn "Xcode is running — quit it before deleting live/shared DerivedData to avoid build errors."
    fi
    $live_sel && warn "Live projects will do a full (slow) rebuild next time."
    if confirm "Delete $(echo $sel | wc -w | tr -d ' ') DerivedData folders ($(human_kb "$sel_kb"))?"; then
        for idx in $sel; do
            remove_path "$(basename "${DD_PATH[idx - 1]}")" "${DD_PATH[idx - 1]}"
        done
        DD_LOADED=false
    fi
}

# 2b. GIT WORKTREES: per-worktree, across every repo under ~
#     $1 = "auto" → pre-select merged + missing · "prune" → only missing (dir gone) records
wt_record() {
    git -C "$1" worktree list --porcelain 2>/dev/null | awk -v target="$2" -v RS= -F '\n' '
        { p = h = b = ""; l = "-"
          for (i = 1; i <= NF; i++) {
              if ($i ~ /^worktree /) p = substr($i, 10)
              else if ($i ~ /^HEAD /) h = substr($i, 6)
              else if ($i ~ /^branch /) b = substr($i, 19)
              else if ($i ~ /^locked/) l = "locked"
          }
          if (p == target) { if (b == "") b = "-"; printf "%s\t%s\t%s\n", h, b, l; exit }
        }'
}

# Save a dirty worktree's tracked edits (patch) and untracked files (tgz), skipping Xcode build dirs.
wt_backup() {
    local wt="$1" br="$2" dest p top
    mkdir -p "$WT_BACKUP_DIR" || return 1
    dest="$WT_BACKUP_DIR/${br//\//-}"; [ "$br" = - ] && dest="$WT_BACKUP_DIR/$(basename "$wt")"
    dest="$dest-$(date +%H%M%S)"
    git -C "$wt" diff HEAD --binary > "$dest.patch" || return 1
    : > "$dest.untracked.txt"
    while IFS= read -r p; do
        top=${p%%/*}
        [ "$top" != "$p" ] && is_xcode_build_dir "$wt/$top" && continue
        echo "$p" >> "$dest.untracked.txt"
    done < <(git -C "$wt" ls-files --others --exclude-standard)
    if [ -s "$dest.untracked.txt" ]; then
        tar -czf "$dest.untracked.tgz" -C "$wt" -T "$dest.untracked.txt" || return 1
    fi
    [ -s "$dest.patch" ] || rm -f -- "$dest.patch"
    ok "Saved changes from $(tildify "$wt") → $(tildify "$dest").*"
}

clean_worktrees() {
    header "Git Worktrees"
    command -v git >/dev/null 2>&1 || { warn "git not found"; return; }
    echo "${DIM}Scanning repos under ~ for linked worktrees...${RESET}"
    load_worktrees
    wt_refresh_open_cwds
    local n=${#WT_PATH[@]} i st color total=0
    if [ "$n" -eq 0 ]; then info "No linked worktrees found"; return; fi

    row "${BOLD}   #  Status    Size     Age   Repo / branch → path${RESET}"
    for ((i = 0; i < n; i++)); do
        st=${WT_STATUS[i]}
        case "$st" in
            prunable|merged) color=$RED ;;
            dirty|orphan|locked-missing|leftover|invalid) color=$YELLOW ;;
            *)               color=$GREEN ;;
        esac
        total=$(( total + WT_KB[i] ))
        row "$(printf "  %2d) ${color}%-8s${RESET}  %-7s %4sd  %s ${DIM}→ %s%s${RESET}" \
            $((i + 1)) "$st" "$(human_kb "${WT_KB[i]}")" "${WT_AGE[i]}" \
            "$(basename "${WT_REPO[i]}"):${WT_BRANCH[i]/#-/detached}" "$(tildify "${WT_PATH[i]}")" \
            "$([ "${WT_LOCK[i]}" = locked ] && echo " (locked)")")"
    done
    info "Total: $(human_kb "$total")"
    info "${RED}prunable${RESET}${DIM} = directory gone · ${RED}merged${RESET}${DIM} = commit in main or PR merged · ${YELLOW}dirty${RESET}${DIM} = uncommitted files (pick by number to back up + remove) · ${YELLOW}orphan${RESET}${DIM} = detached commit with no branch · ${YELLOW}locked-missing${RESET}${DIM} = intentionally retained record · ${YELLOW}leftover${RESET}${DIM} = unregistered directory · ${GREEN}idle${RESET}${DIM} = clean, unmerged or in use"
    info "Missing records are pruned from Git; locked records are kept. Leftovers require a numbered selection and an extra confirmation."

    local sel="" idx
    if [ "${1:-}" = auto ]; then REPLY=s
    elif [ "${1:-}" = prune ]; then REPLY=p
    else
        echo
        echo "  ${BOLD}s${RESET}) safe (merged idle ${WT_IDLE_DAYS}d+, missing)   ${BOLD}p${RESET}) missing records   ${BOLD}1 3 5-7${RESET}) pick   ${BOLD}enter${RESET}) skip"
        ask "> "
    fi
    case "$REPLY" in
        "") info "Skipped"; return ;;
        s)  for ((i = 0; i < n; i++)); do wt_is_safe "$i" && sel="$sel $((i + 1))"; done ;;
        p)  for ((i = 0; i < n; i++)); do [ "${WT_STATUS[i]}" = prunable ] && [ "${WT_LOCK[i]}" != locked ] && sel="$sel $((i + 1))"; done ;;
        *)  sel=$(parse_selection "$REPLY" "$n") ;;
    esac
    if [ -z "$(echo $sel)" ]; then info "Nothing selected"; return; fi

    local sel_kb=0
    for idx in $sel; do
        sel_kb=$(( sel_kb + WT_KB[idx - 1] ))
        case "${WT_STATUS[idx - 1]}" in
            orphan) warn "$(tildify "${WT_PATH[idx - 1]}") has detached commits with no branch; it will be skipped." ;;
            dirty)  info "$(tildify "${WT_PATH[idx - 1]}") has uncommitted files; you'll be asked to save them to $(tildify "$WT_BACKUP_DIR") first." ;;
            idle)   info "$(tildify "${WT_PATH[idx - 1]}") is unmerged; its branch will be kept if removed." ;;
            locked-missing) warn "$(tildify "${WT_PATH[idx - 1]}") is locked and will be skipped." ;;
            leftover) warn "$(tildify "${WT_PATH[idx - 1]}") has no Git registration; inspect its contents before deleting." ;;
        esac
    done
    if confirm "Process $(echo $sel | wc -w | tr -d ' ') worktree entries ($(human_kb "$sel_kb"))?"; then
        local repo wt br record current_sha current_br current_lock
        for idx in $sel; do
            i=$((idx - 1)); repo=${WT_REPO[i]}; wt=${WT_PATH[i]}; br=${WT_BRANCH[i]}
            if [ "${WT_STATUS[i]}" = leftover ]; then
                wt_refresh_open_cwds
                if { [ "$(dirname "$wt")" != "$repo/.worktrees" ] && [ "$(dirname "$wt")" != "$repo/.claude/worktrees" ]; } ||
                   [ ! -d "$wt" ] || [ -L "$wt" ] || [ -e "$wt/.git" ] || wt_in_use "$wt" ||
                   [ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" != "$repo" ]; then
                    warn "$(tildify "$wt") changed or is in use; skipping"
                    continue
                fi
                if confirm "Delete unregistered directory $(tildify "$wt")?"; then
                    if $DRY_RUN; then
                        info "[dry-run] would delete $(tildify "$wt")"
                    elif rm -rf -- "$wt"; then
                        account_kb "${WT_KB[i]}"
                        ok "Deleted leftover $(tildify "$wt") ($(human_kb "${WT_KB[i]}"))"
                    else
                        err "Could not delete $(tildify "$wt")"
                    fi
                fi
                continue
            fi
            record=$(wt_record "$repo" "$wt")
            if [ -z "$record" ]; then warn "$(tildify "$wt") changed since the scan; skipping"; continue; fi
            IFS=$'\t' read -r current_sha current_br current_lock <<< "$record"
            if [ "$current_sha" != "${WT_SHA[i]}" ] || [ "$current_br" != "$br" ] || [ "$current_lock" = locked ]; then
                warn "$(tildify "$wt") changed or is locked; skipping"
                continue
            fi
            if [ "${WT_STATUS[i]}" = prunable ]; then
                if [ -d "$wt" ]; then warn "$(tildify "$wt") reappeared; skipping"; continue; fi
                if $DRY_RUN; then
                    info "[dry-run] would prune missing, unlocked worktree records in $repo"
                elif git -C "$repo" worktree prune --expire=now; then
                    ok "Pruned missing, unlocked worktree records in $(tildify "$repo")"
                else
                    err "Could not prune missing worktree records in $(tildify "$repo")"
                fi
                continue
            fi
            if [ "${WT_STATUS[i]}" = dirty ]; then
                wt_refresh_open_cwds
                if [ ! -d "$wt" ] || wt_in_use "$wt" || [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "${WT_SHA[i]}" ]; then
                    warn "$(tildify "$wt") is missing, in use, or has new commits; skipping"
                    continue
                fi
                confirm "Save $(tildify "$wt")'s uncommitted files to $(tildify "$WT_BACKUP_DIR") and remove it? (branch is kept)" || continue
                if $DRY_RUN; then
                    info "[dry-run] would back up and force-remove $(tildify "$wt")"
                elif wt_backup "$wt" "$br" && git -C "$repo" worktree remove --force "$wt"; then
                    account_kb "${WT_KB[i]}"
                    ok "Removed $(tildify "$wt") ($(human_kb "${WT_KB[i]}"))"
                else
                    err "Backup or removal failed for $(tildify "$wt"); left in place"
                fi
                continue
            fi
            if [ "${WT_STATUS[i]}" != merged ] && [ "${WT_STATUS[i]}" != idle ]; then
                warn "$(tildify "$wt") is not a clean checkout eligible for removal; skipping"
                continue
            fi
            wt_refresh_open_cwds
            if [ ! -d "$wt" ] || wt_in_use "$wt" || [ -n "$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)" ] ||
               [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "${WT_SHA[i]}" ]; then
                warn "$(tildify "$wt") is missing, in use, dirty, or has new commits; skipping"
                continue
            fi
            if [ "${WT_STATUS[i]}" = merged ] && [ "${WT_VIA[i]}" = ancestor ] && ! git -C "$repo" merge-base --is-ancestor "${WT_SHA[i]}" "${WT_BASE[i]}" 2>/dev/null; then
                warn "$(tildify "$wt") is no longer merged; skipping"
                continue
            fi
            if $DRY_RUN; then
                info "[dry-run] would remove $(tildify "$wt")"
            elif git -C "$repo" worktree remove "$wt"; then
                account_kb "${WT_KB[i]}"
                ok "Removed $(tildify "$wt") ($(human_kb "${WT_KB[i]}"))"
                if [ "${WT_STATUS[i]}" = merged ] && [ "$br" != "-" ]; then
                    # a PR-merged tip equals the merged PR head, so -D loses nothing
                    if [ "${WT_VIA[i]}" = pr ]; then git -C "$repo" branch -D "$br" >/dev/null 2>&1 || true
                    else git -C "$repo" branch -d "$br" >/dev/null 2>&1 || true; fi
                fi
            else
                err "Could not remove $(tildify "$wt") — git refused (uncommitted changes?)"
            fi
        done
        WT_LOADED=false; DD_LOADED=false
        info "Their DerivedData is now 'stale' — clear it with menu 2."
    fi
}

# 3. DEVICESUPPORT: per-OS symbol folders copied from physical devices
clean_device_support() {
    header "Device Support Files"
    load_devsupport
    local n=${#DS_PATH[@]} i
    if [ "$n" -eq 0 ]; then info "None present"; return; fi
    row "${BOLD}   #  Size     Age   Platform / OS version${RESET}"
    for ((i = 0; i < n; i++)); do
        local p=${DS_PATH[i]} color=""
        [ "${DS_AGE[i]}" -ge "$OLD_DAYS" ] && color=$YELLOW
        row "$(printf "  %2d) %-7s ${color}%4sd${RESET}  %s / %s" $((i + 1)) "$(human_kb "${DS_KB[i]}")" \
            "${DS_AGE[i]}" "$(basename "$(dirname "$p")" | sed 's/ DeviceSupport//')" "$(basename "$p")")"
    done
    info "Re-downloaded automatically the next time you connect a device on that OS version."
    echo
    echo "  ${BOLD}o${RESET}) older than ${OLD_DAYS} days   ${BOLD}1 3 5-7${RESET}) pick   ${BOLD}all${RESET}) everything   ${BOLD}enter${RESET}) skip"
    ask "> "
    local sel=""
    case "$REPLY" in
        "") info "Skipped"; return ;;
        o)  for ((i = 0; i < n; i++)); do [ "${DS_AGE[i]}" -ge "$OLD_DAYS" ] && sel="$sel $((i + 1))"; done ;;
        *)  sel=$(parse_selection "$REPLY" "$n") ;;
    esac
    if [ -z "$(echo $sel)" ]; then info "Nothing selected"; return; fi
    if confirm "Delete $(echo $sel | wc -w | tr -d ' ') DeviceSupport folders?"; then
        local idx
        for idx in $sel; do remove_path "$(basename "${DS_PATH[idx - 1]}")" "${DS_PATH[idx - 1]}"; done
        DS_LOADED=false
    fi
}

# 4. RUNTIMES: system-wide simulator OS images (~4–8G each) + dyld caches
#    $1 = "auto" → pre-select never-used runtimes with no simulators
clean_runtimes() {
    header "Simulator Runtimes"
    if ! { $HAVE_XCRUN && $HAVE_JQ; }; then
        warn "Needs xcrun and jq (brew install jq)"
        return
    fi
    echo "${DIM}Loading runtimes and measuring dyld caches...${RESET}"
    load_runtimes || { err "Could not read runtime list"; return; }
    local n=${#RT_ID[@]} i used color total=0
    if [ "$n" -eq 0 ]; then info "No runtimes installed"; return; fi

    row "${BOLD}   #  Platform  Version  Build      Image   dyld    Sims  Last used${RESET}"
    for ((i = 0; i < n; i++)); do
        used=${RT_USED[i]}; color=""
        if [ "$used" = never ] && [ "${RT_DEVS[i]}" -eq 0 ]; then color=$YELLOW; fi
        total=$(( total + RT_BYTES[i] / 1024 + RT_CACHE_KB[i] ))
        row "$(printf "  %2d) ${color}%-9s %-8s %-10s %-7s %-7s %4s  %s${RESET}" $((i + 1)) \
            "${RT_PLAT[i]}" "${RT_VER[i]}" "${RT_BUILD[i]}" "$(human_bytes "${RT_BYTES[i]}")" \
            "$(human_kb "${RT_CACHE_KB[i]}")" "${RT_DEVS[i]}" "$used")"
    done
    info "Total incl. dyld caches: $(human_kb "$total")   ${YELLOW}yellow${RESET}${DIM} = never used and no simulators"
    info "Deleted runtimes can be re-downloaded from Xcode → Settings → Components."

    find_orphan_dyld
    local sel=""
    if [ "${1:-}" = auto ]; then
        REPLY=n
    else
        echo
        echo "  ${BOLD}n${RESET}) never used, no sims   ${BOLD}old <platform> <version>${RESET}) e.g. 'old iOS 26.4'"
        echo "  ${BOLD}1 3 5-7${RESET}) pick   ${BOLD}enter${RESET}) skip"
        ask "> "
    fi
    case "$REPLY" in
        "") ;;
        n)
            for ((i = 0; i < n; i++)); do
                [ "${RT_USED[i]}" = never ] && [ "${RT_DEVS[i]}" -eq 0 ] && sel="$sel $((i + 1))"
            done
            ;;
        old\ *)
            local plat ver
            read -r _ plat ver <<< "$REPLY"
            if [ -z "${ver:-}" ]; then warn "Usage: old <platform> <version>"; return; fi
            for ((i = 0; i < n; i++)); do
                [ "$(echo "${RT_PLAT[i]}" | tr A-Z a-z)" = "$(echo "$plat" | tr A-Z a-z)" ] || continue
                ver_lt "${RT_VER[i]}" "$ver" && sel="$sel $((i + 1))"
            done
            ;;
        *) sel=$(parse_selection "$REPLY" "$n") ;;
    esac

    if [ -n "$(echo $sel)" ]; then
        local sel_kb=0 with_devs=0 idx
        echo
        for idx in $sel; do
            i=$((idx - 1))
            sel_kb=$(( sel_kb + RT_BYTES[i] / 1024 + RT_CACHE_KB[i] ))
            info "• ${RT_PLAT[i]} ${RT_VER[i]} (${RT_BUILD[i]})${RT_DEVS[i]:+$( [ "${RT_DEVS[i]}" -gt 0 ] && echo " — ${RT_DEVS[i]} simulators will become unavailable")}"
            [ "${RT_DEVS[i]}" -gt 0 ] && with_devs=$(( with_devs + 1 ))
        done
        if confirm "Delete these $(echo $sel | wc -w | tr -d ' ') runtimes (~$(human_kb "$sel_kb") incl. dyld caches)?"; then
            local caches=""
            for idx in $sel; do
                i=$((idx - 1))
                if run "xcrun simctl runtime delete ${RT_ID[i]}"; then
                    account_kb $(( RT_BYTES[i] / 1024 ))
                    ok "$(done_verb delete Deleted) ${RT_PLAT[i]} ${RT_VER[i]} (${RT_BUILD[i]}): $(human_bytes "${RT_BYTES[i]}")"
                    [ -n "${RT_CACHE_DIR[i]}" ] && caches="$caches${RT_CACHE_DIR[i]}"$'\n'
                else
                    err "Failed to delete ${RT_PLAT[i]} ${RT_VER[i]} — is a simulator on it running?"
                fi
            done
            # Add their dyld caches to the orphan list (simctl doesn't always remove them)
            local c
            while IFS= read -r c; do
                [ -n "$c" ] && ORPHAN_DYLD[${#ORPHAN_DYLD[@]}]="$c"
            done <<< "$caches"
            if [ "$with_devs" -gt 0 ] && confirm "Delete simulators that are now unavailable?"; then
                run "xcrun simctl delete unavailable"
            fi
            RT_LOADED=false; SIM_LOADED=false
        fi
    elif [ -n "$REPLY" ]; then
        info "Nothing matched"
    fi

    # Leftover dyld caches (root-owned → needs sudo)
    if [ "${#ORPHAN_DYLD[@]}" -gt 0 ]; then
        local okb=0 j
        for ((j = 0; j < ${#ORPHAN_DYLD[@]}; j++)); do
            [ -d "${ORPHAN_DYLD[j]}" ] || $DRY_RUN || continue
            okb=$(( okb + $(kb_of "${ORPHAN_DYLD[j]}") ))
        done
        if [ "$okb" -gt 0 ]; then
            echo
            info "${#ORPHAN_DYLD[@]} dyld caches belong to runtimes that are no longer installed ($(human_kb "$okb"))."
            if confirm "Remove them? (needs your admin password)"; then
                for ((j = 0; j < ${#ORPHAN_DYLD[@]}; j++)); do
                    [ -d "${ORPHAN_DYLD[j]}" ] && run "sudo rm -rf \"${ORPHAN_DYLD[j]}\""
                done
                account_kb "$okb"
                ok "$(done_verb remove Removed) orphaned dyld caches: $(human_kb "$okb")"
            fi
        fi
    fi
}

# 5. SIMULATOR DEVICES: per-device size, delete/erase individually
#    $1 = "auto" → only delete unavailable devices
clean_sim_devices() {
    header "Simulator Devices ($(tildify "$SIM_DEVICES"))"
    if ! { $HAVE_XCRUN && $HAVE_JQ; }; then
        warn "Needs xcrun and jq (brew install jq)"
        return
    fi
    if [ "${1:-}" = auto ]; then
        run "xcrun simctl delete unavailable" && ok "$(done_verb "delete" "Deleted") unavailable simulators"
        SIM_LOADED=false
        return
    fi
    load_sims || { err "Could not read simulator list"; return; }
    local n=${#SIM_UDID[@]} i color total=0
    if [ "$n" -eq 0 ]; then info "No simulators"; return; fi

    row "${BOLD}   #  Size     State     Runtime        Name${RESET}"
    for ((i = 0; i < n; i++)); do
        color=""
        [ "${SIM_STATE[i]}" = Booted ] && color=$GREEN
        [ "${SIM_AVAIL[i]}" != true ] && color=$RED
        total=$(( total + SIM_KB[i] ))
        row "$(printf "  %2d) %-7s  ${color}%-9s${RESET} %-14s %s ${DIM}%s${RESET}" $((i + 1)) \
            "$(human_kb "${SIM_KB[i]}")" "${SIM_STATE[i]}" "${SIM_RT[i]}" \
            "${SIM_NAME[i]}" "$( [ "${SIM_AVAIL[i]}" != true ] && echo "(unavailable)")")"
    done
    info "Total: $(human_kb "$total")"
    info "erase = wipe apps + data, keep the device · delete = remove the device entirely"
    echo
    echo "  ${BOLD}u${RESET}) delete unavailable   ${BOLD}d 1 3${RESET}) delete picked   ${BOLD}e 1 3${RESET}) erase picked"
    echo "  ${BOLD}erase-all${RESET}   ${BOLD}delete-all${RESET}   ${BOLD}enter${RESET}) skip"
    ask "> "

    local verb rest sel idx sel_kb=0
    read -r verb rest <<< "$REPLY"
    case "$verb" in
        "") info "Skipped"; return ;;
        u)  run "xcrun simctl delete unavailable" && ok "$(done_verb "delete" "Deleted") unavailable simulators" ;;
        erase-all)
            if confirm "Erase ALL simulator content ($(human_kb "$total"))?"; then
                run "xcrun simctl shutdown all 2>/dev/null || true"
                local before; before=$(kb_of "$SIM_DEVICES")
                run "xcrun simctl erase all"
                $DRY_RUN || account_kb $(( before - $(kb_of "$SIM_DEVICES") ))
            fi
            ;;
        delete-all)
            if confirm "Delete ALL simulators? (Xcode recreates defaults)"; then
                run "xcrun simctl shutdown all 2>/dev/null || true"
                run "xcrun simctl delete all"
                account_kb "$total"
            fi
            ;;
        d|e)
            sel=$(parse_selection "${rest:-}" "$n")
            if [ -z "$(echo $sel)" ]; then info "Nothing selected"; return; fi
            for idx in $sel; do
                sel_kb=$(( sel_kb + SIM_KB[idx - 1] ))
                info "• ${SIM_NAME[idx - 1]} (${SIM_RT[idx - 1]}, $(human_kb "${SIM_KB[idx - 1]}"))"
            done
            local action=delete; [ "$verb" = e ] && action=erase
            if confirm "${action} these $(echo $sel | wc -w | tr -d ' ') simulators (~$(human_kb "$sel_kb"))?"; then
                for idx in $sel; do
                    i=$((idx - 1))
                    [ "${SIM_STATE[i]}" = Booted ] && run "xcrun simctl shutdown ${SIM_UDID[i]}"
                    if run "xcrun simctl $action ${SIM_UDID[i]}"; then
                        account_kb "${SIM_KB[i]}"
                        ok "$(done_verb "$action" "${action}d") ${SIM_NAME[i]} (${SIM_RT[i]})"
                    else
                        err "Failed to $action ${SIM_NAME[i]}"
                    fi
                done
            fi
            ;;
        *) warn "Unknown choice: $REPLY" ;;
    esac
    SIM_LOADED=false; RT_LOADED=false
}

# 6/7. Generic picker for entries of a cache directory over a size threshold
pick_dir_entries() {
    local dir="$1" title="$2" min_kb="${3:-10240}"
    header "$title ($(tildify "$dir"))"
    [ -d "$dir" ] || { info "Not present"; return; }
    echo "${DIM}Scanning...${RESET}"
    du -xsk "$dir"/* "$dir"/.[!.]* 2>/dev/null | awk -v m="$min_kb" '$1 > m' | sort -rn | head -25 > "$TMPD/pick.tsv"

    local paths=() sizes=() i=0 kb path
    while IFS=$'\t' read -r kb path; do
        paths[i]=$path; sizes[i]=$kb
        i=$((i + 1))
    done < "$TMPD/pick.tsv"
    if [ "$i" -eq 0 ]; then info "Nothing over $(human_kb "$min_kb")"; return; fi

    row "${BOLD}   #  Size     Age   Entry${RESET}"
    local j
    for ((j = 0; j < i; j++)); do
        row "$(printf "  %2d) %-7s %4sd  %s" $((j + 1)) "$(human_kb "${sizes[j]}")" \
            "$(age_days "${paths[j]}")" "$(basename "${paths[j]}")")"
    done
    info "Age = days since last modified. Caches regenerate, but apps may re-download content."
    echo
    echo "  ${BOLD}1 3 5-7${RESET}) pick   ${BOLD}enter${RESET}) skip"
    ask "> "
    [ -z "$REPLY" ] && { info "Skipped"; return; }
    case " $REPLY " in *" all "*) warn "Pick numbered cache entries"; return ;; esac
    local sel idx sel_kb=0
    sel=$(parse_selection "$REPLY" "$i")
    if [ -z "$(echo $sel)" ]; then info "Nothing selected"; return; fi
    for idx in $sel; do sel_kb=$(( sel_kb + sizes[idx - 1] )); done
    if confirm "Delete $(echo $sel | wc -w | tr -d ' ') entries ($(human_kb "$sel_kb"))?"; then
        for idx in $sel; do
            remove_path "$(basename "${paths[idx - 1]}")" "${paths[idx - 1]}"
        done
    fi
}

# 8. TIME MACHINE: local snapshots count against free space
clean_time_machine() {
    header "Time Machine Local Snapshots"
    local snaps
    snaps=$(tmutil listlocalsnapshots / 2>/dev/null)
    if [ -z "$snaps" ]; then
        info "No local snapshots"
        return
    fi
    echo "$snaps" | tee -a "$LOG"
    if confirm "Thin local snapshots aggressively?"; then
        run "sudo tmutil thinlocalsnapshots / 999999999999 4"
        ok "Thinned snapshots (may take a few minutes to reclaim space)"
    fi
}

# 9. DOCKER
clean_docker() {
    header "Docker"
    if ! command -v docker >/dev/null 2>&1; then
        info "Docker CLI not found, skipping"
        return
    fi
    if ! docker info >/dev/null 2>&1; then
        warn "Docker daemon not running. Start Docker Desktop to clean."
        return
    fi
    info "Current Docker disk usage:"
    docker system df 2>/dev/null | tee -a "$LOG"
    if confirm "Run 'docker system prune -a --volumes'? (removes unused images, containers, volumes)"; then
        run "docker system prune -a --volumes -f"
    fi
}

# 10. ANDROID SDK — only if you've stopped Android dev
clean_android() {
    header "Android SDK ($(size_of "$HOME/Library/Android"))"
    if [ ! -d "$HOME/Library/Android" ]; then
        info "Not present"
        return
    fi
    du -xsh "$HOME/Library/Android"/* 2>/dev/null | sort -rh | tee -a "$LOG"
    warn "Skip this unless you're sure you don't do Android dev anymore."
    if confirm "Delete ENTIRE Android SDK directory?"; then
        remove_path "Android SDK" "$HOME/Library/Android"
    fi
}

# 11. LOGS
clean_logs() {
    header "Logs ($(size_of "$HOME/Library/Logs"))"
    if confirm "Clear ~/Library/Logs?"; then
        remove_path "User logs" "$HOME/Library/Logs" contents-only
    fi
}

# ── Menu ───────────────────────────────────────────────────────────────────
# Hint text from the last insights scan, if any
hint() { [ -n "$1" ] && printf "%s" "$(human_kb "$1")"; }

menu() {
    local h1 h2 h3 h4 h5 hw hm ht ha hd
    hw=${INS_WT_KB:+$(hint "$INS_WT_KB") total, $(hint "$INS_WT_SAFE_KB") stale}
    h1=${INS_SAFE_KB:+~$(hint "$INS_SAFE_KB") reclaimable}
    h2=${INS_DD_KB:+$(hint "$INS_DD_KB") total, $(hint "$INS_DD_STALE_KB") stale}
    h3=${INS_DS_KB:+$(hint "$INS_DS_KB") total, $(hint "$INS_DS_OLD_KB") old}
    h4=${INS_RT_KB:+$(hint "$INS_RT_KB") total, $(hint "$INS_RT_NEVER_KB") unused}
    h5=${INS_SIM_KB:+$(hint "$INS_SIM_KB") total}
    hm=${INS_MCP_KB:+$(hint "$INS_MCP_KB") total}
    ht=${INS_TEMP_KB:+$(hint "$INS_TEMP_KB") across temp roots}
    ha=${INS_AGENT_CACHE_KB:+$(hint "$INS_AGENT_CACHE_KB") listed}
    hd=${INS_MCP_KB:+$(hint "$INS_MCP_KB") MCP, $(hint "$INS_TEMP_KB") temp}
    cat <<EOF

${BOLD}Disk Cleanup — choose what to run${RESET}
  ${DIM}(everything destructive shows details and confirms first)${RESET}

  ${CYAN}i)${RESET}  Insights report           ${DIM}— rescan and show what's reclaimable${RESET}
  ${CYAN}d)${RESET}  Developer storage         ${DIM}— read-only MCP, agent, and temp details  ${hd}${RESET}

  ${GREEN}1)${RESET}  Package manager caches    ${DIM}— brew, npm, pnpm, pip, uv, SwiftPM  ${h1}${RESET}
  ${GREEN}2)${RESET}  Xcode DerivedData         ${DIM}— per project, flags deleted projects  ${h2}${RESET}
  ${GREEN}3)${RESET}  Device support files      ${DIM}— symbols from physical devices  ${h3}${RESET}
  ${GREEN}4)${RESET}  Simulator runtimes        ${DIM}— OS images + dyld caches  ${h4}${RESET}
  ${GREEN}5)${RESET}  Simulator devices         ${DIM}— per device, delete or erase  ${h5}${RESET}
  ${GREEN}6)${RESET}  ~/Library/Caches picker   ${DIM}${INS_LC_KB:+— $(hint "$INS_LC_KB")}${RESET}
  ${GREEN}7)${RESET}  ~/.cache picker           ${DIM}${INS_DC_KB:+— $(hint "$INS_DC_KB")}${RESET}
  ${GREEN}8)${RESET}  Time Machine snapshots
  ${GREEN}9)${RESET}  Docker prune
  ${GREEN}10)${RESET} Android SDK               ${DIM}— only if you've stopped Android dev${RESET}
  ${GREEN}11)${RESET} Logs
  ${GREEN}12)${RESET} XcodeBuildMCP outputs     ${DIM}— selected workspace build products  ${hm}${RESET}
  ${GREEN}13)${RESET} Temporary Xcode builds    ${DIM}— selected build directories  ${ht}${RESET}
  ${GREEN}14)${RESET} Agent app caches          ${DIM}— selected Claude and Codex caches  ${ha}${RESET}
  ${GREEN}w)${RESET}  Git worktrees             ${DIM}— merged/missing/dirty, across repos under ~  ${hw}${RESET}

  ${BOLD}a)${RESET}  ${BOLD}Recommended sequence${RESET}      ${DIM}— 1, merged worktrees, stale DerivedData, unused runtimes, unavailable sims${RESET}
  ${BOLD}q)${RESET}  Quit

EOF
    printf "Choose: "
    read -r choice || { echo; return 1; }
    case "$choice" in
        i|I) insights ;;
        d|D) developer_storage_report ;;
        1)  clean_safe_caches ;;
        2)  clean_derived_data ;;
        3)  clean_device_support ;;
        4)  clean_runtimes ;;
        5)  clean_sim_devices ;;
        6)  pick_dir_entries "$HOME/Library/Caches" "App caches" ;;
        7)  pick_dir_entries "$HOME/.cache" "CLI caches" ;;
        8)  clean_time_machine ;;
        9)  clean_docker ;;
        10) clean_android ;;
        11) clean_logs ;;
        12) clean_mcp_builds ;;
        13) clean_temp_builds ;;
        14) clean_agent_caches ;;
        w|W) clean_worktrees ;;
        a|A)
            clean_safe_caches
            clean_worktrees auto       # before DerivedData: removed worktrees make theirs stale
            clean_derived_data auto
            clean_runtimes auto
            clean_sim_devices auto
            ;;
        q|Q) return 1 ;;
        *) warn "Unknown choice: $choice" ;;
    esac
    return 0
}

# ── Main ───────────────────────────────────────────────────────────────────
say "Disk Cleanup — $(date)"
say "Host: $(hostname)"
$DRY_RUN && warn "DRY-RUN MODE: nothing will be deleted"
$AUTO_SAFE && warn "SAFE-ALL MODE: running zero-risk cleanups automatically"

if $DEV_STORAGE_ONLY; then
    developer_storage_report
    say "Full log: $LOG"
    exit 0
fi

if $MCP_BUILDS_ONLY || $TEMP_BUILDS_ONLY || $AGENT_CACHES_ONLY || $DERIVED_ONLY; then
    $MCP_BUILDS_ONLY && clean_mcp_builds
    $TEMP_BUILDS_ONLY && clean_temp_builds
    $AGENT_CACHES_ONLY && clean_agent_caches
    $DERIVED_ONLY && clean_derived_data
    say "Full log: $LOG"
    exit 0
fi

if $WORKTREES_ONLY; then
    if $PRUNE_WORKTREES; then clean_worktrees prune; else clean_worktrees; fi
    say "Full log: $LOG"
    exit 0
fi

disk_snapshot

if $ANALYZE_ONLY; then
    insights
    say ""
    say "Analysis-only mode complete. Report: $LOG"
    exit 0
fi

if $AUTO_SAFE; then
    clean_safe_caches
    clean_worktrees prune      # only git records whose directory is already gone
    clean_derived_data auto    # only folders whose project no longer exists
    clean_sim_devices auto     # only unavailable simulators
else
    $STARTUP_SCAN && insights
    while menu; do :; done
fi

# ── Final summary ──────────────────────────────────────────────────────────
header "Summary"
if $DRY_RUN; then
    say "Would free this session: ~$(human_kb $TOTAL_FREED_KB)"
else
    say "Total freed this session: $(human_kb $TOTAL_FREED_KB)"
    disk_snapshot
fi
say ""
say "Full log: $LOG"
$DRY_RUN && say "${YELLOW}(dry-run — no actual deletions performed)${RESET}"
