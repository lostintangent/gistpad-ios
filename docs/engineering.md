# Engineering choices

Checked against current Apple documentation on October 23, 2026. The implementation is a Phase 0 spike, not a claim of finished product quality.

| Choice | Reason and primary reference |
|---|---|
| Xcode 27.1 SDK, iOS 27.1 minimum | Full Duo adaptation and current layout APIs, without compatibility branches for this personal phone. [Duo preparation](https://developer.apple.com/iphone-duo/prepare/) |
| Swift 6 language mode | Strict concurrency is enabled by the language mode. UI state and input stay `@MainActor`. Cross-module edit payloads are value types and `Sendable`. No unchecked concurrency bypasses. [Swift 6 adoption](https://developer.apple.com/documentation/swift/adoptingswift6) |
| `@Observable` document sessions | SwiftUI observes only the state it reads. A session, not a transient view, owns canonical Markdown, generation and the source text view. [Observation in SwiftUI](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app) |
| SwiftUI app/navigation/toolbars | Prefer system components and their automatic Liquid Glass, accessibility and Duo behavior. Glass belongs to controls/navigation, not a translucent writing canvas. [Liquid Glass adoption](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) |
| Native `NavigationSplitView` for Library | Standard sidebar/detail behavior and compact collapse. Explicit Focus is a separate navigation root, not three narrow columns. [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) |
| `ArrangementView` for Focus | Source and preview adapt to reserved regions. Do not nest the arrangement inside a competing split layout or infer geometry from the hinge angle. The session survives changes of presentation. [ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview) |
| `UITextView(usingTextLayoutManager: true)` via `UIViewRepresentable` | Deliberate UIKit boundary. A plain `TextEditor` does not provide the required attributed highlighting and precise text-system control. TextKit 2 retains selection, undo, IME, dictation, find and system Writing Tools. Never access the legacy layout manager. [TextKit 2 initializer](https://developer.apple.com/documentation/uikit/uitextview/init(usingtextlayoutmanager:)) |
| Attribute-only syntax highlighting | Never assign replacement strings or attributed strings during SwiftUI updates. Defer decoration while marked text or Writing Tools is active. Code/frontmatter are excluded from Writing Tools. [Writing Tools exclusion delegate](https://developer.apple.com/documentation/uikit/uitextviewdelegate/textview(_:writingtoolsignoredrangesinenclosingrange:)) |
| `NSRange` and `NSString` at input/bridge boundaries | Deliberate Foundation APIs matching UIKit's UTF-16 coordinates and JavaScript source offsets. Validate bounds, surrogate boundaries, expected source, document identity and generation before editing. Swift `String` remains the canonical source. |
| Swift Testing | Unit and package tests use `@Test`, `#expect` and serialized main-actor suites where UIKit requires it. UI automation can use XCTest because Swift Testing does not replace XCUITest. [Swift Testing](https://developer.apple.com/documentation/testing) |
| String Catalogs | `Localizable.xcstrings`, SwiftUI localizable literals and Xcode extraction. Synthetic note content and diagnostic identifiers are not translations. Production UI must not assemble sentences through concatenation. [String Catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) |
| Semantic colors and Dynamic Type | Native resolved colors are authoritative. The preview receives the same appearance/font metrics, rather than approximating system colors in CSS. Text styles, contrast, VoiceOver and reduced motion are acceptance criteria. See `design-system.md`. |
| Local Swift packages | Editor, renderer and future sync code evolve independently of the app project. The app owns signing and integration. UIKit state stays out of renderer event types. |

## Phase 0 evidence and limits

- Package tests validate UTF-16 mutations, duplicate task positions and protected syntax ranges.
- iOS tests exercise the actual TextKit 2 object across width changes, undo, marked text and rehosting.
- Every visual surface needs Designer review on Duo cover/open, light/dark and Large/AX3 Dynamic Type before it can be considered production-ready.
- Programmatic marked text is not a real Japanese keyboard candidate session. Simulator posture is not a hardware fold. Device input, Writing Tools and keyboard state are separate remaining gates.
- Authentication, local persistence and cloud sync are not implied by a running editor. This build explicitly labels its in-memory fixture and never claims that changes were saved.
- No App Store work, CloudKit, custom window activation, hinge gestures or unsupported conditional GitHub writes.
