#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: ./install.sh [--skill NAME] [--target codex|claude|both] [--scope user|project] [--force]
       ./install.sh --list

Omit --skill for an interactive skill picker.
EOF
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target="both"
scope="user"
selected=""
force="false"
list_only="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skill) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; selected="$2"; shift 2 ;;
    --target) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; target="$2"; shift 2 ;;
    --scope) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; scope="$2"; shift 2 ;;
    --force) force="true"; shift ;;
    --list) list_only="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$target" in codex|claude|both) ;; *) printf 'Invalid target: %s\n' "$target" >&2; exit 2 ;; esac
case "$scope" in user|project) ;; *) printf 'Invalid scope: %s\n' "$scope" >&2; exit 2 ;; esac

list_skills() {
  count=0
  for skill_dir in "$repo_root"/skills/*; do
    [ -d "$skill_dir" ] && [ -f "$skill_dir/SKILL.md" ] || continue
    count=$((count + 1))
    skill_name=$(basename "$skill_dir")
    description=$(awk '
      /^description:/ {
        sub(/^description:[[:space:]]*/, "")
        if ($0 == "" || $0 == ">-" || $0 == "|-") {
          getline
          sub(/^[[:space:]]+/, "")
        }
        print
        exit
      }
    ' "$skill_dir/SKILL.md")
    printf '%s\t%s\t%s\n' "$count" "$skill_name" "$description"
  done
}

if [ "$list_only" = "true" ]; then
  list_skills | while IFS="$(printf '\t')" read -r number skill_name description; do
    [ -n "$skill_name" ] && printf '%s. %s — %s\n' "$number" "$skill_name" "$description"
  done
  exit 0
fi

if [ -z "$selected" ]; then
  if [ ! -t 0 ]; then
    printf 'Choose a skill with --skill NAME. Available skills:\n' >&2
    "$0" --list >&2
    exit 2
  fi
  printf 'Available skills:\n'
  list_skills | while IFS="$(printf '\t')" read -r number skill_name description; do
    [ -n "$skill_name" ] && printf '%s. %s — %s\n' "$number" "$skill_name" "$description"
  done
  printf 'Choose a number or enter a skill name: '
  read -r choice
  case "$choice" in
    ''|*[!0-9]*) selected="$choice" ;;
    *) selected=$(list_skills | awk -F '\t' -v n="$choice" '$1 == n { print $2 }') ;;
  esac
fi

skill_dir="$repo_root/skills/$selected"
if [ ! -f "$skill_dir/SKILL.md" ]; then
  printf 'Unknown skill: %s\nAvailable skills:\n' "$selected" >&2
  "$0" --list >&2
  exit 2
fi

install_one() {
  agent="$1"
  if [ "$scope" = "user" ]; then
    case "$agent" in
      codex) parent="${HOME:?HOME is not set}/.agents/skills" ;;
      claude) parent="${HOME:?HOME is not set}/.claude/skills" ;;
    esac
  else
    case "$agent" in
      codex) parent="$PWD/.agents/skills" ;;
      claude) parent="$PWD/.claude/skills" ;;
    esac
  fi
  destination="$parent/$selected"
  if [ -e "$destination" ] && [ "$force" != "true" ]; then
    printf 'Already exists; left unchanged: %s (use --force to update)\n' "$destination" >&2
    return 1
  fi
  mkdir -p "$destination"
  cp -R "$skill_dir/SKILL.md" "$destination/"
  for item in references examples scripts assets LICENSE ATTRIBUTION.md; do
    [ -e "$skill_dir/$item" ] && cp -R "$skill_dir/$item" "$destination/"
  done
  printf 'Installed %s for %s: %s\n' "$selected" "$agent" "$destination"
}

status=0
case "$target" in
  codex) install_one codex || status=1 ;;
  claude) install_one claude || status=1 ;;
  both) install_one codex || status=1; install_one claude || status=1 ;;
esac
exit "$status"
