# iOS and macOS 27.2 opportunities

Owner: Platform (M4). Status: research only, no implementation.
Evidence: Xcode 27.2 (27B52) `iPhoneOS27.2.sdk` and `MacOSX27.2.sdk` interfaces, plus Apple's iOS 27.2, macOS 27.2, and Xcode 27.2 release notes.

## Summary

Nothing in 27.2 changes a visible GistPad surface that the Designer needs to approve. The useful adoptions are a QA tool now and three small items for later. Most 27.2 additions are for other domains.

## Ranked opportunities

| # | Opportunity | 27.2 API or tool | User benefit | Effort | Decision |
|---|---|---|---|---|---|
| 1 | Test the Duo editor and Ask/Edit/Review under memory pressure | Xcode 27.2 Device Hub memory-pressure simulation, Standby on Duo | Catches editor and model memory regressions before the installed-device pass | Small, no code | Adopt now for QA |
| 2 | Leading inline titles on sheets | `View.toolbarTitleAlignment(_:)` with `ToolbarTitleAlignment` (`iOS 27.2`, iOS only) | Only if the Designer wants a leading title. Notes uses the system default, so no change by default | Tiny | Later, Designer call |
| 3 | Shortcuts can pipe note text into GistPad intents | `IntentParameter` inits with `inputConnectionBehavior:` for `_IntentValueRepresentable` values, and the collection `size:` variant (`anyAppleOS 27.2`). Entity-typed parameters such as `NoteEntity` stay on the iOS 18 inits | Shortcuts chains such as "Add to Today" from other apps' output | Small to medium, plus t12 acceptance | Later, for text and bool parameters only |
| 4 | Pass structured note content to on-device Ask/Edit/Review | FoundationModels `DataAttachmentRepresentable`, `supportsDataAttachmentType(_:)`, `supportsDataEntryType(_:)`, `Transcript.DataEntry`, `LanguageModelExecutorGenerationChannel` data actions (27.2) | Could carry photos or other typed content without inflating the text prompt | Medium, needs a spike and a context-budget check on Duo | Later, spike only if photo-aware Ask is wanted |

## Skip

- **UIKit title alignment and `UIView.LayoutRegion.bar`.** The app is SwiftUI, and `toolbarTitleAlignment` covers the same need.
- **ATT changes.** GistPad does no tracking.
- **StoreKit external purchase deprecations, ProximityReader, `showNotice`.** No purchase or payment flow.
- **BackgroundAssets, CoreMotion, CoreImage, HealthKit, LiveCommunicationKit, MarketplaceKit, Matter, NowPlaying, SharedWithYou.** No GistPad use.
- **WidgetKit, CoreSpotlight, AppIntents core.** The 27.2 SDK adds no WidgetKit or CoreSpotlight API. Keep the current IndexedEntity and interactive widget design.
- **WritingTools.** No 27.2 change. `writingToolsBehavior` (iOS 18) and the AppIntents `_ModelDelegationConfiguration.writingTools` (27.0) are unchanged, so the current `UIWritingToolsCoordinator` setup stays.
- **`.xcproj` JSON project format.** Not needed for v1.
- **`Date` comparison operators.** Already back-deployed, so no change.

## macOS

- macOS 27.2 adds only FoundationModels, Foundation, BackgroundAssets, and LiveCommunicationKit items. SwiftUI and AppKit add none. None of these change GistPad's UI.
- A real Mac target is not warranted for v1. The project builds only `iphoneos iphonesimulator`, and Catalyst is off.
- The project does not set any Mac-designed flags. I did not verify how Xcode 27.2 defaults an iOS build on Apple silicon Macs. Verify before the user relies on running it on a Mac.
- Known Xcode 27.2 issue: it reports the 27.1 deployment target as valid for macOS and Catalyst. Irrelevant while the target is iOS only.

## 27.1 and 27.2 behavior changes to check

- **UIKit default layout margins are zero on iOS 27.1+.** This already applies to us because our minimum was 27.1. Check the two `UIViewRepresentable` views (`MarkerCaptureContrast`, `ScrollEdgeReadiness`). No code change is proposed. The Designer checks the Dark captures for layout shifts.
- **Xcode 27.2 requires macOS Tahoe 26.6 or later.** Lead's build machine must meet this.
- **Deployment target.** `release/build-23` (`ad39472`) raises `IPHONEOS_DEPLOYMENT_TARGET` and every package platform to 27.2. Nothing else in the project needs the bump.
- **Shortcuts "Describe a Shortcut" known issue.** Our phrases use `AppShortcutsProvider`, not this feature. Cover Shortcuts in the t12 installed-device pass.

## Open checks

1. Item 3's availability is confirmed in the 27.2 SDK. Check at adoption time that the `@Parameter` wrapper accepts `inputConnectionBehavior:`, since the wrapper's own signature wasn't verified.
2. Measure FoundationModels context cost on Duo before any item 4 spike.
3. Confirm the Mac-designed default in Xcode 27.2 before anyone relies on it.
