# Mobile Dev Skills

A curated collection of installable Agent Skills for designing and building mobile apps. Each skill
is independent, so install only the guidance you need. Skills use the shared `SKILL.md` format and
work with Codex and Claude Code.

## Available skills

| Skill | What it helps with | Install name |
| --- | --- | --- |
| [Mobile App Design](skills/mobile-app-design/SKILL.md) | Design, implement, redesign, and review iOS and Android app screens across SwiftUI, UIKit, Jetpack Compose, and React Native. | `mobile-app-design` |

More skills can be added under `skills/<skill-name>/SKILL.md`. The installer lists available skills
and lets you select one by name or choose from a menu.

## Install one skill

Clone or download this repository, then run:

```sh
./install.sh --skill mobile-app-design --target both --scope user
```

If `--skill` is omitted, the installer displays a numbered list so you can choose. Use `--target
codex` or `--target claude` to install for one agent. Use `--scope project` to install into the
current project. Existing skills are left alone unless you pass `--force`.

Codex locations: `~/.agents/skills/` (user) and `.agents/skills/` (project). Claude Code locations:
`~/.claude/skills/` (user) and `.claude/skills/` (project).

You can also install a selected skill with the Skills CLI, which discovers skills in this repo's
`skills/` directory:

```sh
npx skills add https://github.com/prasadpamidi/mobile-dev-skills --skill mobile-app-design
```

## Add a skill

1. Create `skills/<skill-name>/SKILL.md` with the required `name` and `description` frontmatter.
2. Add only focused references, examples, or scripts that materially support that skill.
3. Add the skill to the table above and keep its attribution and license with the skill.
4. Confirm the root installer can discover it; do not rename its `name` field separately from its
   install name.

## Licensing and attribution

Each skill carries its own attribution and license information. Check the skill's directory before
redistributing or combining its contents. The first skill adapts selected principles from
[Taste Skill by Leonxlnx](https://github.com/Leonxlnx/taste-skill) and includes its MIT notice.

## Maintainers

Keep the collection focused on mobile app design and implementation. Prefer a new skill when it has
a distinct job and its own workflow; keep related platform notes together as references when they
share the same goal.
