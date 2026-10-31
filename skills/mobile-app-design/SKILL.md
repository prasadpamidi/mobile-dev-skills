---
name: mobile-app-design
description: >-
  Design, implement, redesign, or review native mobile app screens and flows for iOS and Android,
  including SwiftUI, UIKit, Jetpack Compose, and React Native. Use when a mobile interface feels
  generic, when adapting an existing app, or when a task needs platform-aware interaction design,
  responsive layouts, accessibility, and polished implementation. Not for web-only marketing pages.
---

# Mobile App Design

Create mobile interfaces that feel specific to the product and at home on their platform. Replace
generic decoration with decisions grounded in the product's real content, workflows, and constraints.
Preserve useful upstream Taste Skill principles: begin with the subject, choose a clear design
direction, avoid interchangeable layouts, and review the rendered result. Apply them in a mobile
context; do not import web-only rules or rigid visual prohibitions.

## Workflow

### 1. Understand the product and existing app

Identify the primary user, their most important task, the app's platform(s), framework, existing
design system, navigation structure, real content and data, and any required behavior. Inspect the
existing screen or code before redesigning. Keep working routes, state, and interaction behavior
unless the request changes them. When a brief is incomplete, make a reasonable assumption and state
it briefly; ask only if a missing detail blocks useful work.

Write a short product inventory: specific terminology, real user goals, objects or data unique to this
product, constraints, and the moments where a person uses the app. From it, choose one visual or
interaction idea that belongs to this product. Apply the idea to hierarchy, content, or behavior, not
as a decorative motif. If the same idea would fit every competing app, make it more specific.

### 2. Choose a direction and platform behavior

Use the product's character and existing design system to choose type, color, density, geometry,
imagery, and motion. Reuse established tokens and components when present. For new work, state a
one-sentence direction before building; offer a small number of meaningfully different options only
when the user asks to explore.

Treat iOS and Android as related products with shared intent and distinct platform behavior. Follow
the conventions of the target platform for navigation, system bars, menus, dialogs, back behavior,
selection, and feedback. Avoid putting a web page inside a phone frame or copying platform chrome
across systems without a reason. For cross-platform apps, share brand, content, and task structure;
adapt interaction details to each platform where users expect them.

### 3. Design the whole task, not only the happy-path screenshot

For each screen, define its purpose, primary action, content hierarchy, navigation context, and what
changes after interaction. Design relevant loading, empty, error, disabled, success, permission,
offline, and destructive-confirmation states. Use real or clearly marked representative content;
never invent testimonials, metrics, or user data as proof.

Make the primary task easy to reach and understand. Keep frequent actions in comfortable thumb
reach where appropriate, without making a fixed bottom action obscure content or the keyboard. Ensure
controls communicate their role and state. Use motion and haptics only when they clarify a result,
relationship, or spatial change; honor reduced-motion settings and provide non-haptic feedback.

### 4. Adapt to people and device contexts

Respect system safe areas, status/navigation bars, cutouts, home indicators, and edge-to-edge
behavior. Adapt to available window size, orientation, fold posture, split-screen, and tablets when
the product supports them. Use reflow, additional panes, or navigation changes where they improve the
task; do not merely stretch a phone layout across a large display.

Support large text and font scaling, localization and right-to-left layout, sufficient contrast,
screen readers, keyboard and switch access where relevant, and accessible names and focus order.
Prefer flexible content and constraints over fixed heights. Make touch targets comfortably usable
and avoid relying on color, position, or gesture alone to convey meaning. Read
[`references/platform-decisions.md`](references/platform-decisions.md) for platform-specific choices
and framework examples.

### 5. Implement with the project's stack

Use the existing framework, architecture, components, and dependencies. For SwiftUI, prefer native
navigation and system controls where they fit; for UIKit, use the platform's semantic controls and
layout guides. For Compose, use Material components and window-aware adaptive layouts as appropriate.
For React Native, use platform-aware components and insets rather than assuming identical system
behavior. Keep screen composition, state, and reusable components coherent with the repository.

Implement enough real interaction to make the design credible: working controls, state changes,
validation, and navigation appropriate to the task. Do not replace functional flows with static mock
screens. Do not add dependencies when the existing stack can deliver the result.

### 6. Review the rendered experience

Run the app or preview the relevant screen when tools and environment allow. Inspect at least one
compact phone size and a larger text setting; also inspect a larger window or second platform when
the scope includes them. Look for clipped content, awkward wrapping, unsafe-area collisions,
keyboard overlap, cramped tap targets, inconsistent spacing, missing states, and controls that do
not behave as shown. Fix the highest-impact issues, then summarize what changed and what you could
not inspect. For a review-only request, report concrete findings with screen/state and impact.

Use [`references/review-checklist.md`](references/review-checklist.md) for a compact final pass.
Use [`examples/screen-direction.md`](examples/screen-direction.md) as a short example of turning a
brief into mobile-specific design decisions.

## Scope and judgment

This skill guides design and implementation choices; it does not require a particular style. Keep a
brand's distinctive language, use platform conventions as defaults rather than inflexible laws, and
explain intentional exceptions. Prefer clear, durable, accessible interfaces over novelty that makes
the task harder.
