# Usage Guide

This guide explains how to work with Claude Code **after** running Claude Code Smart Bootstrap.

The main idea is simple: give Claude the **task and acceptance criteria**, not repeated setup instructions. The bootstrap already configures the context, memory, code-intelligence, visual-cache, model, and repair workflow.

## The prompt format that works best

For normal work, a short structured prompt is enough:

```text
Goal:
<what you want changed>

Scope:
<screen / feature / files / behavior involved>

Reference:
<optional local design/reference path>

Constraints:
<important things that must stay true>

Done when:
<how you will know the task is finished>
```

Example:

```text
Goal:
Fix the inventory screen spacing and bottom-sheet behavior.

Scope:
Inventory screen only.

Reference:
design-reference/sheet.png

Constraints:
Keep the existing navigation and data model unchanged.

Done when:
The rendered screen matches the reference closely and the bottom sheet behaves correctly.
```

You do **not** need to add tool instructions such as “use Graft”, “read CLAUDE.md”, “use Context Mode”, or “remember the previous chat”. Those behaviors are already part of the installed workflow.

## Batch related requirements together

Prefer one coherent request:

```text
Update the inventory screen:
- fix card spacing
- correct the top inset
- match button radius to the reference
- keep the current navigation
- build and verify the screen
```

Instead of sending five tiny prompts one by one.

This reduces back-and-forth, repeated repository exploration, and repeated reasoning.

## Reusable images and design references

If an image will be used more than once, keep it as a local project file instead of re-uploading it every conversation.

Recommended layout:

```text
my-app/
└── design-reference/
    ├── sheet.png
    ├── home.png
    └── stats.png
```

First use of a new reference:

```text
Use and register design-reference/home.png as the canonical home-screen reference.
```

Later conversations:

```text
Match the home screen to design-reference/home.png.
```

Exact image content is fingerprinted. If the pixels are unchanged, the stored visual spec/crops can be reused without another full image-analysis pass.

If the image is only temporary and will not be reused, a normal chat attachment is fine.

## When the design still looks wrong

Do not re-upload the same image immediately.

Say what is wrong:

```text
The inventory screen still differs from design-reference/sheet.png:
- title is too low
- cards are too narrow
- bottom navigation is too tall

Compare the current render with the cached reference and fix those mismatches.
```

This lets the workflow reuse the existing reference and focus only on the mismatch.

## New conversation vs long conversation

Use a **new Code conversation in the same repository** when:

- you are moving to a different task;
- the current conversation has become very long;
- a clean working context would be easier.

You do not need to restate the entire project history.

A good new-session prompt is:

```text
Continue work on this repository.

Goal:
Fix the freezer-item edit flow.

Reuse prior project decisions and known fixes when relevant.
```

Context Mode, Auto Memory, and project-state are intended to recover relevant prior information when needed.

## Repeated or previously solved bugs

If you think the problem happened before, say so directly:

```text
This looks like an issue we solved before.
Check prior project-state/history before investigating from scratch, then verify against the current code.
```

You do not need to describe the old fix again if you do not remember it.

## Large logs and command output

Avoid pasting huge logs unless they are the only available source.

Prefer:

```text
The build failed. Inspect the local build output and fix the first real root cause.
```

If you must paste logs, include the smallest useful section around the error.

The installed workflow is designed to keep large tool output out of the parent conversation where possible.

## Good prompt examples

### Normal coding task

```text
Goal:
Add swipe-to-delete to freezer items.

Constraints:
Keep Room schema unchanged.
Show an undo action.
Preserve the current visual style.

Done when:
The interaction works, tests/build pass, and no unrelated files are changed.
```

### UI task with a reference

```text
Goal:
Make the stats screen match design-reference/sheet.png.

Scope:
Stats screen only.

Constraints:
Keep the current data calculations.
Do not redesign unrelated screens.

Done when:
Render/diff shows no obvious layout, spacing, typography, or color mismatch.
```

### Bug fix

```text
Goal:
Fix the app opening the onboarding flow for returning users.

Constraints:
Do not replace the current single-activity navigation architecture.

Done when:
Returning users land on Home and new users still see onboarding.
```

### Continue previous work

```text
Continue the previous work on this repository.

Goal:
Finish the inventory-screen fixes that are still unresolved.

Use prior decisions, known issues, and cached design references where relevant.
```

## Things you normally should not type

After the bootstrap is healthy, these reminders should not be necessary:

```text
read CLAUDE.md
use Graft
use Graphify
remember the previous conversation
use Context Mode
/compact
/graphify .
re-read the whole repository
```

Also avoid re-uploading the same reusable design image when a stable local copy already exists.

## Model behavior

The configured workflow keeps the main conversation stable:

```text
Main conversation      → Sonnet / medium
Visual implementation  → Sonnet / high subagent
Hard visual QA         → bounded Opus / high escalation
```

You normally do not need to switch the main model manually for routine work.

## A compact default prompt

If you want one reusable pattern, use this:

```text
Goal:
<task>

Reference:
<optional local path>

Constraints:
<only the important constraints>

Done when:
<clear acceptance criteria>
```

That is usually enough.
