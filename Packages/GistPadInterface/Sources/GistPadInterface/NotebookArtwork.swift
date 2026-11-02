#if os(iOS)
import SwiftUI

struct NotebookArtwork: View {
    var body: some View {
        Image("Notebook", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }
}
#endif
