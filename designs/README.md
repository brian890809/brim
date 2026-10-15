# Notch window-tabs prototype

Open `notch-window-tabs.html` directly in a browser. It is self-contained, including the app's existing monochrome logos; no build, account access, or external libraries are needed.

This is a design study, not a native app implementation. All percentages, identities, and reset times are sample data.

## Direction A

- Keep the existing 520 × 150 logical-pixel dashboard, with a 38px illustrative top reserve, black silhouette, typography, and margins.
- Codex retains its weekly allowance and timestamp. Do not fabricate a five-hour Codex window. Additional Codex limits must be driven by verified provider data if implemented later.
- Claude's timestamp row becomes 5-hour / Weekly / Fable tabs. Account identity remains visible. Fable is an illustrative model-specific weekly limit, not a context capacity.
- Selection changes the percentage, bar, and reset time in place. No automatic cycling or resizing. Selection survives collapse/reopen within the page, not a browser reload.
- A small amber dot marks a low allowance (10% or less) even when another window is selected. Missing data is shown as an em dash, not 100%.

## Interactions

Click Claude's tabs, or use left/right arrows and Home/End while a tab is focused. The sample-data selector includes low-allowance and missing-model-data scenarios. The footer can simulate provider selection, pinning, automatic refresh, refresh, and compact/open states. Account management, app launch, and quit are disabled.

Use 1× with browser zoom at 100% to assess native-scale density. Larger preview zooms are inspection aids, not alternative app dimensions. Narrow browser panels scroll the preview horizontally rather than shrinking the app's type.

## Validation

Verified in the in-app browser: Claude tab selection, keyboard right-arrow navigation, low-allowance indicators, selected-window retention across collapse/reopen, missing-data rendering, no reset-line overflow at 1×, successful logo loads, and unchanged 520 × 150 dashboard bounds across the tested states. The current Codex mockup has no tabs. Reduced-motion CSS disables transitions. No native source, installed app, credentials, or release was changed.
