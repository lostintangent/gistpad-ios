# iOS and macOS 27.2 opportunities

Owner: Platform. Status: research only, no implementation.
Evidence: Xcode 27.2 (27B52) `iPhoneOS27.2.sdk` and `MacOSX27.2.sdk` interfaces, plus Apple's iOS 27.2, macOS 27.2, and Xcode 27.2 release notes.

## Summary

Nothing in 27.2 changes a visible GistPad surface that the Designer needs to approve. The useful adoptions are a QA tool now and three small items for later. Most 27.2 additions are for other domains.

## Ranked opportunities

| # | Opportunity | 27.2 API or tool | User benefit | Effort | Decision |
|---|---|---|---|---|---|
| 1 | Test the Duo editor and Ask/Edit/Review under memory pressure | Xcode 27.2 Device Hub memory-pressure simulation, Standby on Duo | Catches editor and model memory regressions before the installed-device pass | Small, no code | Adopt now for QA |
| 2 | Leading inline titles on sheets | `View.toolbarTitleAlignment(_:)` with `ToolbarTitleAlignment` (`iOS 27.2`, iOS only) | Only if the Designer wants a leading title. Notes uses the system default, so no change by default | Tiny | Later, Designer call |
| 3 | Shortcuts can pipe note text into GistPad intents | `IntentParameter` inits with `inputConnectionBehavior:` for `_IntentValueRepresentable` values, and the collection `size:` variant (`anyAppleOS 27.2`). Entity-typed parameters such as `NoteEntity` stay on the iOS 18 inits | Shortcuts chains such as "Add to Today" from other apps' output | Small to medium, plus a phone check | Later, for text and bool parameters only |
| 4 | Pass structured note content to on-device Ask/Edit/Review | FoundationModels `DataAttachmentRepresentable`, `supportsDataAttachmentType(_:)`, `supportsDataEntryType(_:)`, `Transcript.DataEntry`, `LanguageModelExecutorGenerationChannel` data actions (27.2) | Could carry photos or other typed content without inflating the text prompt | Medium, needs a spike and a context-budget check on Duo | Later, spike only if photo-aware Ask is wanted |

## Skip

- **UIKit title alignment and `UIView.LayoutRegion.bar`.** The app is SwiftUI, and `toolbarTitleAlignment` covers the same need.
- **ATT changes.** GistPad does no tracking.
- **StoreKit external purchase deprecations, ProximityReader, `showNotice`.** No purchase or payment flow.
- **BackgroundAssets, CoreMotion, CoreImage, HealthKit, LiveCommunicationKit, MarketplaceKit, Matter, NowPlaying, SharedWithYou.** No GistPad use.
- **WidgetKit, CoreSpotlight, AppIntents core.** The 27.2 SDK adds no WidgetKit or CoreSpotlight API. Keep the current IndexedEntity and interactive widget design.
- **WritingTools.** No 27.2 change. `writingToolsBehavior` (iOS 18) and the AppIntents `_ModelDelegationConfiguration.writingTools` (27.0) are unchanged, so the current `UIWritingToolsCoordinator` setup stays.
- **`Date` comparison operators.** Already back-deployed, so no change.

## macOS

- macOS 27.2 adds only FoundationModels, Foundation, BackgroundAssets, and LiveCommunicationKit items. SwiftUI and AppKit add none. None of these change GistPad's UI.
- A real Mac target is not warranted. The project builds only `iphoneos iphonesimulator`, Catalyst is off and no Mac-designed flags are set. I did not verify how Xcode 27.2 defaults an iOS build on Apple silicon Macs, so check that before anyone relies on running it on a Mac.

## Open checks

1. Item 3's availability is confirmed in the 27.2 SDK. Check at adoption time that the `@Parameter` wrapper accepts `inputConnectionBehavior:`, since the wrapper's own signature wasn't verified.
2. Measure FoundationModels context cost on Duo before any item 4 spike.
