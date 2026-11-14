#if os(iOS)
import SwiftUI

// Pin and Archive read the same in swipes, menus and More, and show what a tap does.
extension Button where Label == SwiftUI.Label<Text, Image> {
    init(pinned: Bool, action: @escaping () -> Void) {
        self.init(
            pinned ? String(localized: "Unpin", bundle: .module) : String(localized: "Pin", bundle: .module),
            systemImage: pinned ? "pin.slash" : "pin", action: action)
    }

    init(archived: Bool, action: @escaping () -> Void) {
        self.init(
            archived ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
            systemImage: archived ? "arrow.up.bin" : "archivebox", action: action)
    }
}
#endif
