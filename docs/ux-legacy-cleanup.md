# ThinkAloud Legacy and Fallback Cleanup Record

Date: 2026-07-31
Status: canonical cleanup implemented; final build, localization validation, offline unit suite, and
targeted manual runtime inspection passed on 2026-08-01.

## Scope and policy

This cleanup covers compatibility branches, silent fallbacks, and best-effort paths found while
remediating the 42-surface Nielsen/HIG audit. The canonical behavior is defined by the current
settings schemas, dataset schema, deletion protocol, benchmark report model, and upload contract.
Backward compatibility is intentionally not preserved where it would require guessing user intent,
silently changing data, or claiming success without proof.

Absence and corruption are different:

- An absent first-run preference may use the current product default.
- A present but malformed canonical preference is an error; it is not silently decoded as a default.
- A genuinely optional domain value, such as “no LLM edit was performed,” remains optional.
- An incompatible dataset row is rejected with a precise recovery path; the app does not invent an
  auto-edited transcript.

## Ranked removed paths and canonical replacements

| Rank | Removed legacy/fallback path | Why it was unsafe | Canonical replacement |
|---|---|---|---|
| `P0` | Settings “clear all” deleted database rows only; browser deletion treated recording-file removal as best effort. | The UI could report deletion while private recordings remained orphaned and no longer attributable to records. | One shared `DatasetDeletionService` writes an atomic manifest, stages the exact audio files, performs the database mutation transactionally, purges only after commit, serializes competing deletes, and reconciles interrupted batches before the UI/hotkeys publish at startup. |
| `P0` | Hugging Face repository creation treated HTTP `409` as sufficient success, trusted requested visibility, and silently skipped missing audio. | A requested private push could target an existing public repository, or publish metadata that referenced absent audio. | Push preflight requires every selected recording, applies visibility for both new and existing repositories, reads effective visibility back before pre-upload/commit, aborts on mismatch, and reports pre-/post-commit staging cleanup according to the real external side effect. |
| `P1` | New saves could omit `autoEditedTranscript`, while downstream statistics/export/upload selected substitute baselines conditionally. | Different consumers could disagree about the canonical transcript stage, and a fallback could conceal structurally incomplete records. | New `DatasetRecord` saves require Auto Post-Edit text. The SQLite column remains nullable only for pre-v0.4 rows whose missing intermediate cannot be reconstructed; those legacy rows are preserved and excluded from edit metrics rather than guessed. Current statistics and Hugging Face metadata use `llmEditedTranscript ?? autoEditedTranscript` only when a captured baseline exists. |
| `P1` | Saved settings accepted partial/malformed Codable shapes, invalid enum raw values fell back to defaults, and the retired `ThinkAloud.chinesePreference` key was migrated indefinitely. | Corrupt or obsolete state could silently change model, editing, denoise, or idle behavior and remain impossible to diagnose. | Current configuration types use one canonical encoded shape. A missing key initializes the current default; a present invalid key throws a typed `SavedSettingsError`. The startup recovery UI identifies and can reset only the offending key. Persist failures are logged and exposed through observable Settings state. The retired migration is removed. |
| `P2` | Benchmark reports allowed missing normalized metrics and audio duration, then rendered guessed values such as `0 ms` or empty text. | Incomplete results looked valid and made comparisons/export internally inconsistent. | The report’s normalized metrics and duration fields are required, so incomplete historical JSON no longer decodes as a valid report. The runner turns missing, undecodable, empty, or zero-duration audio into an explicit error row; every newly produced successful row has positive decoded duration. |
| `P2` | User-critical operations used `try?`, log-only catches, raw HTTP bodies, or `String(describing:)` as presentation fallback. | Failures appeared as loading/empty/success, exposed technical data, or offered unrelated recovery. | Critical UI paths use typed localized errors and explicit loading/error/retry states. Raw framework/network detail is retained in diagnostics, while UI copy describes the failed task and appropriate recovery destination. |

## Canonical invariants

| Area | Required invariant |
|---|---|
| Startup | Dataset save/deletion reconciliation completes successfully before the container, windows, or global shortcuts become usable. A precise blocker with Retry/Quit is shown on failure. |
| Dataset save | A save manifest exists before audio persistence; interrupted saves are reconciled instead of silently losing or duplicating the recording. |
| Dataset deletion | The exact requested IDs and their recordings reach one atomic, reconcilable outcome; unrelated records added after confirmation are not deleted. |
| Dataset transcript stages | Raw and final text are required. New saves also require auto-edited text; historical rows with an unknowable missing intermediate remain nullable and are excluded from edit metrics. LLM-edited text is optional because the LLM stage itself may not run. |
| Insights history | Every completed Insert attempt has one stable session ID and stores full transcript stages plus metadata, never audio. Dataset membership and deletion are independent. |
| Saved settings | No key means current default. A malformed present key means typed failure and targeted reset, never an implicit migration or default. |
| Hugging Face push | Complete local audio and verified effective remote visibility are preconditions to commit. Cancellation is checked at external side-effect boundaries. |
| Benchmark result | A successful row has complete normalized outputs, metrics, and positive source duration. Missing evidence is a failure, not zero. |
| Error presentation | User-visible status is localized and actionable; raw diagnostics do not become UI copy. |

## Final validation evidence

The final offline suite ran after the canonical settings, dataset, benchmark, localization, and UI
behavior edits converged. The later visual-only button sizing modifier received a clean app build
and manual zh-Hant runtime check:

- `xcodebuild test`: **223 executed, 1 skipped, 0 failures**.
- `git diff --check`: passed.
- The localization catalog test confirmed live-key closure, complete zh-Hant values, and matching
  interpolation/format signatures.
- Live ASR and LLM smoke suites were intentionally excluded because they download and load real
  models; they are not fallback/contract tests.
- The isolated app was manually inspected after the final visual changes. No UI automation was run
  in the final pass, per the user's explicit request.

The final command was:

```sh
xcodebuild -project ThinkAloud.xcodeproj -scheme ThinkAloud \
  -configuration Debug \
  -derivedDataPath <isolated-derived-data> \
  -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -disableAutomaticPackageResolution -skipMacroValidation \
  -skipPackagePluginValidation test \
  -only-testing:ThinkAloudTests \
  -skip-testing:ThinkAloudTests/LiveASRSmokeTest \
  -skip-testing:ThinkAloudTests/LLMSmokeTest
```

The result bundle is
`/Users/jacoblincool/Library/Developer/Xcode/DerivedData/ThinkAloud-akxczrsejfbwdteewebutprhigiv/Logs/Test/Test-ThinkAloud-2026.08.01_01-00-47-+0800.xcresult`.

No removed path should be restored as a compatibility fallback. If a future migration is required,
it must be explicit, one-way, independently tested, and must fail closed when it cannot preserve
the current data or privacy contract.
