# Mobile Dev Skills

A modular marketplace of portable Agent Skills for the full mobile app development lifecycle. The
collection is broad; each installable skill has a focused job, so people can pick only what they
need. Skills use the shared `SKILL.md` format and work with Codex and Claude Code.

## What belongs here

- Product shaping and mobile UI/UX design
- Native iOS development with SwiftUI and UIKit
- Native Android development with Jetpack Compose and Views
- App architecture, data and service integration, and platform capabilities
- Accessibility, testing, debugging, performance, security, release, and maintenance

These are areas for the catalog, not one all-purpose skill. Add each skill when it has a clear,
reusable workflow of its own.

## Available skills

| Area | Skill | What it helps with | Install name |
| --- | --- | --- | --- |
| Design | [Mobile App Design](skills/mobile-app-design/SKILL.md) | Design, implement, redesign, and review mobile screens and flows with native platform behavior in mind. | `mobile-app-design` |

`mobile-app-design` is the first focused listing, not the name or full scope of the marketplace.
Add more installable skills under `skills/<skill-name>/SKILL.md`. The installer lists available
skills and lets people choose one by name or from a menu.

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

Keep the collection focused on mobile app development. Prefer a new skill when it has a distinct job
and its own workflow; keep closely related notes together as references when they share the same goal.
