# macOS responsive layout

The main SwiftUI window uses three width classes in `Sources/MainView.swift`:

- `narrow`: below 720 points
- `compact`: 720–1039 points
- `regular`: 1040 points and wider

The supported minimum content size is 620 × 520 points. Keep primary download,
search, status, and per-record actions reachable at that size. Manual download
settings use an adaptive grid; Smart Mode replaces that grid with a resolved
profile summary so automatic and manual choices are never shown together.

For repeatable visual checks, generate all six Smart/Manual snapshots with:

```bash
./scripts/test_responsive_ui.sh /tmp/link2download-responsive-snapshots
```

Verify all three sizes in both Smart and Manual modes. Check that controls do not
clip horizontally, the history toolbar keeps its overflow menu visible, metadata
can scroll when needed, and expanded record details wrap at narrow widths.
