# Startup feedback contract v1

The startup feedback contract describes the phase feedback both products render
while the workbench is not ready yet. It exists because a cold start performs
plugin discovery, language service initialization, workspace opening, and
session restoration; without feedback the user cannot tell a slow start from a
hung application.

The contract is portable. It owns the phase vocabulary, the outcome vocabulary,
the timing thresholds, and the exact wording both products display. It does not
own when a phase starts, how long it runs, or how a failure is produced; those
remain platform behavior.

## Outcomes

Both products expose one logical state machine:

`idle` → `loading` → `ready`

A failed phase enters `failed` instead of `ready`. `failed` carries the phase
that failed and a stable failure code; the human readable reason stays
platform-owned because it describes platform diagnostics.

| Outcome | Meaning |
| --- | --- |
| `idle` | The feedback surface exists but nothing is being reported yet. |
| `loading` | A phase is running and the current phase is shown. |
| `ready` | The workbench is usable; the feedback layer is dismissed. |
| `failed` | A phase failed; the failed phase and reason are shown. |

## Phases

| Order | Phase | Progress | Meaning |
| --- | --- | --- | --- |
| 1 | `preparing` | 10 | The product shell is being prepared before any phase runs. |
| 2 | `loadingPlugins` | 30 | Installed plugins or extensions are being discovered and validated. |
| 3 | `initializingLanguageServices` | 50 | Language services are being prepared. |
| 4 | `openingWorkspace` | 72 | The workspace is being opened and indexed. |
| 5 | `restoringSession` | 88 | The previous session is being restored. |

The progress column is the percentage a progress indicator shows while that
phase runs. It is part of the contract so both products report the same number
for the same phase; a product may animate towards the value, but the value it
settles on is the one in this table. The indicator reaches 100 when the outcome
turns `ready`.

A phase is a coarse product level step. The detailed language service
preparation phases (`starting`, `importing`, `configuring`, `building`,
`ready`, `stopped`) keep their own vocabulary in
[`../fixtures/lsp/project-preparation-v1.json`](../fixtures/lsp/project-preparation-v1.json);
the startup phase `initializingLanguageServices` summarizes them and must not
replace them.

Products report the phase that is currently running. A product does not have to
report every phase: a phase that already completed before the feedback surface
became visible is not replayed, and a product without session restoration never
reports `restoringSession`.

## Timing

- `minimumVisibleDurationMs` is the skip threshold. A product that reaches
  `ready` within this window after the feedback surface becomes visible never
  shows the startup animation, so a fast start adds no visible delay.
- `fadeOutDurationMs` is the shared fade-out duration applied when the outcome
  turns terminal. Both products use the same duration so the transition reads
  identically.

The feedback layer never delays readiness. It is a presentation of work that
already happens; the animation must not add waiting time to the product.

## Failure

A failed phase is reported with the phase id and one of these codes:

| Code | Meaning |
| --- | --- |
| `pluginLoadFailed` | Plugin discovery or validation failed. |
| `languageServiceInitializationFailed` | Language service preparation failed. |
| `workspaceOpenFailed` | The workspace could not be opened. |
| `sessionRestoreFailed` | The previous session could not be restored. |

The failure state must stay dismissible. The user can always continue into the
product; a failure overlay must not permanently block the workbench.

## Presentation rules

- The feedback layer is a presentation of the startup state. It does not own
  startup work, does not start plugins, and does not open workspaces.
- Both products show the same phase wording for the same phase. The wording in
  [`../fixtures/settings/startup-feedback-v1.json`](../fixtures/settings/startup-feedback-v1.json)
  is the canonical text and is verified against both products.
- The feedback layer follows each product's theme. Light and dark appearances
  use the product's own surface and text colors instead of hard coded colors.
- A product may offer a setting that disables the feedback layer. Disabling it
  removes the animation and never adds delay.
