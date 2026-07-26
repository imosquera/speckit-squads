---
description: "Create or update the GitHub issue tracking the current feature's spec"
---

# Sync Feature Issue

Create or update the GitHub issue that tracks the current feature, rendering its body from the feature's `spec.md`.

`/speckit-git-feature` opens the tracking issue with a stub body (its number drives the spec/branch numbering). This command fills that stub in — and keeps it current on every later re-spec. It runs automatically on the `after_specify` hook, and can be invoked directly as `/speckit-git-issue` at any time.

This command is idempotent: re-running it rewrites the same issue body from the current spec rather than creating duplicates or appending.

## Locating the Feature

Resolve the feature directory the same way the other git commands do:

1. `$SPECIFY_FEATURE_DIRECTORY` when set.
2. Otherwise `feature_directory` from `.specify/feature.json`.

The spec is `<feature directory>/spec.md`. If neither the feature directory nor the spec file can be resolved, stop with a clear error.

## GitHub Issue Integration (Required)

`gh` **MUST** be installed and authenticated. If `gh` is missing, `gh auth status` fails, or the create/edit call itself fails, stop with a clear error — never silently skip the sync.

1. Read `.specify/feature.json`.
2. If it has a numeric `source_issue`, update that issue:
   `gh issue edit <source_issue> --title "<title>" --body "<body>"`
3. Otherwise create one:
   `gh issue create --title "<title>" --body "<body>"`
   then parse the issue number out of the returned URL and persist it back into `.specify/feature.json` as a numeric `source_issue`, preserving every other key in the file. Subsequent runs then take the update path.

The title is the spec's H1, prefixed with the feature number when the branch/spec is numbered (e.g. `008: User Auth`), matching the title `/speckit-git-feature` set.

## Issue Body

Derive the body from **whatever sections `spec.md` actually contains** — do not assume a fixed set. Presets may add or remove sections, so read the file and render only the headings that are present. If a section is absent, skip its heading entirely rather than emitting an empty one.

```markdown
Spec path: <feature directory>/spec.md

<one-paragraph summary of the feature>

## User Scenarios

<condensed from the spec's user scenarios section>

## Functional Requirements

<the spec's functional requirements>

## Notes

Generated/updated by /speckit-git-issue
```

**`## Success Criteria` is deliberately omitted.** Presets such as `spec-minimal` strip that section out of `spec.md`, so demanding it here would require inventing content that does not exist. The same reasoning applies to any other optional section: render it only if the spec has it.

## Graceful Degradation

There is none by design — issue sync is mandatory when it runs:

- `gh` missing or unauthenticated → hard error with an install / `gh auth login` hint.
- No feature directory or no `spec.md` → hard error.
- `gh issue create` / `gh issue edit` non-zero exit → hard error, surfacing `gh`'s own message.
