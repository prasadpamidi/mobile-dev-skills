# Platform decisions and implementation notes

Use this as a decision aid, not a catalog of mandatory components. Confirm current platform guidance
when a system pattern or API detail matters.

## iOS

- Use tab bars for top-level destinations and toolbars for actions within the current view. Preserve
  navigation state when switching top-level areas where that matches the app's model.
- Keep standard Back and Close behavior recognizable. Prefer system navigation, sheets, menus,
  pickers, and controls when they fit the task; customize only when the product benefits from it.
- Respect safe areas and system materials. Make content scroll beneath bars only when it remains
  readable and interactive. Consider Dynamic Type, Dark Mode, orientation, and iPad window sizes.
- Put frequent actions where they are comfortable to reach. Keep essential actions reachable when
  the keyboard appears, and avoid covering content with persistent controls.

## Android

- Use Android navigation, system back, dialogs/sheets, menus, and Material components in ways users
  recognize. Use Material 3 as a foundation when it fits the product, not as a visual identity by
  itself.
- Make layout decisions from available app-window size, not device labels alone. Consider compact,
  medium, and expanded widths; foldables, rotation, resizable windows, and multi-window use.
- Use system bars and edge-to-edge layouts deliberately. Maintain readable contrast and clear
  separation between app content and system-owned areas.
- Support font scaling and non-touch input where the app's form factors make them relevant.

## Framework mapping

| Stack | Prefer | Check |
| --- | --- | --- |
| SwiftUI | `NavigationStack`, `TabView`, system controls, safe-area-aware layout, Dynamic Type | State ownership, sheet dismissal, large text, compact/regular adaptation |
| UIKit | `UINavigationController`, `UITabBarController`, semantic controls, Auto Layout and layout guides | Insets, content-size changes, keyboard avoidance, rotation and split view |
| Jetpack Compose | Material 3 components, state hoisting, window-size-aware layout, adaptive navigation when useful | Back handling, font scale, insets, fold/window changes, recomposition/state |
| React Native | Existing navigation library, platform-aware components, safe-area/inset handling | iOS and Android back behavior, keyboard, status bars, accessibility semantics, platform-specific polish |

## Cross-platform boundary

Share information architecture, content meaning, brand tokens, and core behavior. Adapt system
navigation, control semantics, gestures, menus, feedback, and spacing to platform expectations when
that improves predictability. Avoid branching every component by platform; adapt at clear screen or
interaction boundaries.

## Example: adaptive navigation choice

- A compact phone with four frequently used areas may use a labeled bottom tab bar.
- A tablet or expanded window may retain the same destinations but present them in a navigation rail
  or sidebar alongside a list-detail layout.
- Keep the same selected destination, labels, and content model across those layouts. Change the
  presentation based on available window space, not a hard-coded device name.
