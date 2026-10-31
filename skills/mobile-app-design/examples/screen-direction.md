# Example: brief to screen direction

## Brief

Design a screen for a neighborhood plant-care app. It should help a person quickly see which plant
needs attention today. Existing project has a warm green palette and a three-tab structure.

## Product inventory

- People use it while moving around their home, often one-handed.
- The important information is the plant name, room, next care task, and due time.
- The app already uses friendly plant names and clear, calm language.
- Existing tabs and plant records should remain intact.

## Direction

Make today's care list feel like a useful field note: one clear next task first, with room and due
time easy to scan. Keep the product's green tokens and tab navigation. Use a compact top summary,
then individual plant rows with a small plant image, name, room, and a plainly labeled “Mark watered”
action. Avoid turning each item into a colorful dashboard card.

## Interaction and states

- Marking a plant watered updates its next-care date and gives a brief confirmation.
- Empty state says all plants are cared for today and offers the next useful destination.
- Loading state keeps the content frame stable; errors offer retry without losing list context.
- The action stays reachable at larger text sizes and does not cover list rows.

## Adaptation

On a larger window, keep the list readable and use a second pane for the selected plant's care
history. On iOS, preserve the existing tab and navigation behavior. On Android, preserve system back
and the app's existing navigation pattern.
