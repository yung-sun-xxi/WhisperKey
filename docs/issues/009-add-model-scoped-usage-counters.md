# Add model-scoped usage counters

## Summary

Add durable usage counters that are independent from transcription history.

The app should track usage even when text history is disabled or trimmed. The tracked usage must not store transcription text. The main popover should show compact usage stats for the currently selected provider/model, with a selectable time range.

## Product behavior

The command center header should show usage for the current `provider + model`.

The supported ranges are:

- `Today`
- `Last 7 Days`
- `Last 30 Days`
- `All Time`

The selected range should persist per user.

The usage line should display units in this order:

```text
words · audio time · estimated money
```

Examples:

```text
155 words · 42s · ~$0.01
8.2k words · 3h 14m · ~$1.26
```

Use `~` for money because the app stores a local estimate based on the known provider/model pricing at transcription time.

## Scope

This feature is not a text-history feature.

Text history may still be controlled by the existing history retention setting. Usage counters must continue to work when history size is `0`.

The usage store must not persist transcription text.

## Usage data

Store usage entries separately from `HistoryStore.entries`.

Each usage entry should include:

- `id`
- `createdAt`
- `providerID`
- `modelID`
- `wordCount`
- `audioDurationSeconds`
- `estimatedPriceAtTime`
- `currency`

The cost must be stored at transcription time. Old usage entries should not be recalculated if pricing rules change later.

## Pricing rules

Every provider/model exposed by the app UI must have a pricing rule in `TranscriptionCostEstimator`.

Missing pricing for a supported model is a developer error, not a normal runtime state.

Recommended guardrail:

- Add tests that iterate through every `OpenAIProvider.Model.allCases` and `GroqProvider.Model.allCases`.
- Assert that `TranscriptionCostEstimator.estimate(...)` returns a value for each supported model.

The transcription itself should not fail solely because local usage recording failed, but missing pricing should be logged as an error and covered by tests so it does not ship unnoticed.

## Model scoping

Usage summaries must be filtered by:

1. Current provider.
2. Current model.
3. Selected time range.

Switching provider or model in Settings should automatically switch the visible stats in the popover.

Example:

```text
OpenAI · whisper-1
1.2k words · 18m · ~$0.11

OpenAI · gpt-4o-mini-transcribe
340 words · 4m · ~$0.01
```

These are separate counters.

## Reset counters

Settings should include a `Reset Counters...` action.

Pressing it should open a dialog/window with a selectable list of supported provider/model combinations.

The reset UI should include:

- Checkbox list of models.
- `Select Current`.
- `Select All`.
- Destructive `Reset Selected` action.
- Cancel action.

Resetting counters deletes usage data only for the selected provider/model combinations. It must not delete transcription history text.

## Install reset

Usage counters should reset after each installation performed through the app's installer flow.

Preferred implementation:

- Installer writes a new install marker.
- On launch, the app detects an unprocessed install marker.
- The app clears usage counters once.
- The app marks that install marker as processed.

This is more diagnosable than having an installer script directly delete app data.

Manual drag-and-drop replacement of the `.app` may not pass through the installer flow and therefore may not reliably reset counters.

## Implementation outline

1. Add a `UsageStatsStore` package or type separate from `HistoryStore`.
2. Persist usage data to Application Support, for example `usage-stats.json`.
3. Record usage after a successful non-empty transcription.
4. Keep existing `HistoryStore` behavior for text history.
5. Add a usage range enum and summary filtering.
6. Persist selected usage range in `SettingsStore`.
7. Update `CommandCenterHeader` to show a segmented range control and current-model summary.
8. Add the Settings reset UI.
9. Add installer-marker handling for install-time counter resets.
10. Add tests for range filtering, model scoping, reset behavior, and pricing coverage.

## Acceptance criteria

- Usage counters update after each successful non-empty transcription.
- Counters still update when text history size is `0`.
- Usage entries do not store transcription text.
- Popover stats are scoped to the current provider/model.
- `Today`, `Last 7 Days`, `Last 30 Days`, and `All Time` show correct summaries.
- Selected range persists across app launches.
- Settings can reset counters for selected models.
- Resetting counters does not clear transcription history.
- Installer-driven reinstall resets usage counters once.
- Every app-supported provider/model has a tested pricing rule.
