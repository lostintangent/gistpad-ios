#if os(iOS)
import SwiftUI

struct GistPadArtwork: View {
    var body: some View {
        Image("Artwork", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }
}
#endif
