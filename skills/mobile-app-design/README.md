# Mobile App Design skill

A portable Agent Skill for designing, implementing, redesigning, and reviewing mobile app screens
across iOS and Android, including SwiftUI, UIKit, Jetpack Compose, and React Native.

## Install

Extract the archive, then run the installer from this folder:

```sh
./install.sh --target both --scope user
```

Targets are `codex`, `claude`, or `both`. Scope is `user` (personal, available across projects) or
`project` (install into the current working directory). The installer does not overwrite an existing
skill unless you pass `--force`; force updates files in place and leaves unrelated files alone.

Install locations:

| Target | User scope | Project scope |
| --- | --- | --- |
| Codex | `~/.agents/skills/mobile-app-design/` | `.agents/skills/mobile-app-design/` |
| Claude Code | `~/.claude/skills/mobile-app-design/` | `.claude/skills/mobile-app-design/` |

Codex scans `.agents/skills` in the current repository and `~/.agents/skills` for personal skills.
Claude Code uses `.claude/skills` in a project and `~/.claude/skills` for personal skills. Restart
the relevant agent if a newly installed skill does not appear.

To install only for one agent:

```sh
./install.sh --target codex --scope user
./install.sh --target claude --scope project
```

## Contents

- `SKILL.md` — shared instructions and workflow.
- `references/platform-decisions.md` — iOS, Android, and framework-specific decisions.
- `references/review-checklist.md` — compact render and accessibility review.
- `examples/screen-direction.md` — example brief translated into product-specific mobile decisions.
- `install.sh` — guarded installer for Codex and Claude Code.
- `ATTRIBUTION.md` and `LICENSE` — upstream attribution and MIT license notice.

## Use

Invoke `mobile-app-design` explicitly or describe the mobile design task. The skill is also written
for automatic matching through its `SKILL.md` description.

## Sources and conventions checked

- Upstream principles and license: [Leonxlnx/taste-skill](https://github.com/Leonxlnx/taste-skill)
- Codex skill format and discovery: [OpenAI Build skills](https://learn.chatgpt.com/docs/build-skills)
- Claude Code skill format and discovery: [Claude Code Skills](https://code.claude.com/docs/en/skills)
- Mobile guidance: [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/), [Android adaptive apps](https://developer.android.com/develop/adaptive-apps/)
