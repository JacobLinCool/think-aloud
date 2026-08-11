# ThinkAloud UX Audit Plan

- Date: 2026-07-31
- Product: ThinkAloud, a menu-bar-first native macOS voice-input application.
- Platform: Native macOS 15+ application built with SwiftUI and AppKit.
- Audit goal: Full-surface, pre-remediation audit followed by implementation and regression verification.
- Scope boundary: All user-visible app surfaces and meaningful states in the repository: onboarding, menu bar menu, dictation popup, Settings, dataset browser and record detail, Insights, benchmark, Hugging Face push, model/download states, permissions, updates, confirmation dialogs, empty/loading/error/success states, keyboard operation, VoiceOver-facing semantics, localization, and window behavior. The marketing site, OS-owned permission/update dialogs, model quality, ASR accuracy, and external Hugging Face web UI are out of scope except where the app launches or explains them.
- Target users: New and returning macOS users who dictate into other apps; keyboard-first and pointer users; VoiceOver, reduced-motion, increased-contrast, and larger-text users; English and Traditional Chinese users.
- Target tasks:
  1. Complete first-run setup, understand privacy, grant permissions, choose/download a model, and learn the core shortcut.
  2. Start, stop, review, edit, cancel, insert, and save a dictation; understand progress and recover from failures.
  3. Open the menu bar menu and find status, Insights, Settings, dataset browsing, updates, and Quit.
  4. Configure startup, shortcuts, output, permissions, ASR models, AI refinement, dataset handling, advanced options, rerun setup, and updates.
  5. Browse, search/filter/select, play, edit, save, and delete dataset records; interpret empty and detail states.
  6. Run, compare, normalize, inspect, export, cancel, and recover from a benchmark.
  7. Review local Insights and achievement states.
  8. Configure and perform a Hugging Face push with informed privacy choices and actionable error recovery.
- Entry points: First launch, menu bar icon/menu, global shortcut, Settings command, Browse Dataset command, and Insights command.
- Auth assumptions: Signed in to the local macOS account; no Hugging Face account/token by default. System permission and OS-owned dialogs may vary by machine state.
- Coverage rule: Every in-scope source-defined surface gets a stable manifest row; every target task gets a primary path plus available cancel/error/recovery paths; runtime inspection covers every state that can be safely induced without destructive external actions or multi-gigabyte downloads, while inaccessible states are verified from source and explicitly labeled.
- Heuristic frame:
  - Nielsen’s 10 usability heuristics, evaluated individually.
  - Applicable Apple Human Interface Guidelines for macOS: windows and navigation, menus, settings, buttons and controls, feedback, progress, alerts, text and labels, keyboard, accessibility, privacy, onboarding, localization, destructive actions, and platform conventions.
- Severity model:
  - `S4 / P0 — Critical`: blocks a critical task, risks irreversible loss/privacy harm, or makes the app unusable for a supported access method.
  - `S3 / P1 — Major`: causes frequent failure, serious confusion, inaccessible primary functionality, or no practical recovery.
  - `S2 / P2 — Moderate`: adds recurring friction or violates a clear platform convention but has a discoverable workaround.
  - `S1 / P3 — Minor`: localized polish, wording, or efficiency issue with low task impact.
  - `S0 — Conforms`: no observed violation for the audited surface.
- Evidence model: A finding requires a concrete source reference and/or runtime state, task impact, violated principle, severity, confidence, and remediation. “Feels confusing” is not sufficient evidence.
- Deliverables:
  - Stable interaction surface manifest and task-flow map.
  - Before-fix audit matrix covering all Nielsen heuristics and applicable HIG areas.
  - Implemented fixes with focused automated tests.
  - After-fix runtime, accessibility, localization, build, and test verification.
  - Final residual-risk statement; “fully compliant” will only be claimed for the explicitly covered and verifiable scope.
- Artifacts:
  - `docs/ux-audit-plan.md`
  - `docs/ux-surface-manifest.csv`
  - `docs/ux-usability-audit.md`
  - `scripts/ux_audit/` for repeatable runtime inspection where useful
  - `output/ux-audit/` for screenshots and machine-readable evidence (not required to be committed)
