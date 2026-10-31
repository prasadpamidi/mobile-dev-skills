#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: ./install.sh [--target codex|claude|both] [--scope user|project] [--force]

  --target   Which agent to install for (default: both)
  --scope    user installs to the home skill directory;
             project installs into the current directory (default: user)
  --force    Update files if the destination already exists
  --help     Show this help
EOF
}

target="both"
scope="user"
force="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      target="$2"
      shift 2
      ;;
    --scope)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      scope="$2"
      shift 2
      ;;
    --force)
      force="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$target" in codex|claude|both) ;; *) printf 'Invalid target: %s\n' "$target" >&2; exit 2 ;; esac
case "$scope" in user|project) ;; *) printf 'Invalid scope: %s\n' "$scope" >&2; exit 2 ;; esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
skill_name="mobile-app-design"

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

  destination="$parent/$skill_name"
  if [ -e "$destination" ] && [ "$force" != "true" ]; then
    printf 'Already exists; left unchanged: %s\nUse --force to update it.\n' "$destination" >&2
    return 1
  fi

  mkdir -p "$parent"
  mkdir -p "$destination"
  cp -R "$script_dir/SKILL.md" "$script_dir/ATTRIBUTION.md" "$script_dir/LICENSE" "$destination/"
  cp -R "$script_dir/references" "$script_dir/examples" "$destination/"
  printf 'Installed %s skill: %s\n' "$agent" "$destination"
}

status=0
case "$target" in
  codex) install_one codex || status=1 ;;
  claude) install_one claude || status=1 ;;
  both)
    install_one codex || status=1
    install_one claude || status=1
    ;;
esac
exit "$status"
