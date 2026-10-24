#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import GistPadAppearance

@MainActor
struct AccentTraitTests {
    @Test("Picker colors are converted from Display P3 to opaque sRGB")
    func pickerColorSpace() throws {
        let input = UIColor(displayP3Red: 0.3, green: 0.6, blue: 0.2, alpha: 1)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let converted = try #require(input.cgColor.converted(to: colorSpace, intent: .defaultIntent, options: nil))
        let components = try #require(converted.components)
        let result = try #require(RGBColor(uiColor: input))
        #expect(result.red == UInt8((min(1, max(0, components[0])) * 255).rounded()))
        #expect(result.green == UInt8((min(1, max(0, components[1])) * 255).rounded()))
        #expect(result.blue == UInt8((min(1, max(0, components[2])) * 255).rounded()))
        #expect(result != RGBColor(red: 77, green: 153, blue: 51))
        #expect(RGBColor(uiColor: input.withAlphaComponent(0.5)) == nil)
    }

    @Test("Dynamic native roles use the same quantized colors in all four appearances")
    func nativeRoles() throws {
        for saved in ["#FACC15", "#FFFFFF", "#000000", "#FF00FF", "#0EA5E9"] {
            for dark in [false, true] {
                for increased in [false, true] {
                    let traits = UITraitCollection {
                        $0.userInterfaceStyle = dark ? .dark : .light
                        $0.accessibilityContrast = increased ? .high : .normal
                        $0[PersonalAccentTrait.self] = PersonalAccent(savedHex: saved)
                    }
                    let roles = PersonalAccent(savedHex: saved).roles(traits: traits)
                    let target = increased ? 7.0 : 4.5
                    for surface: UIColor in [
                        .systemBackground, .secondarySystemBackground, .tertiarySystemBackground,
                        .systemGroupedBackground, .secondarySystemGroupedBackground, .tertiarySystemGroupedBackground
                    ] {
                        let rgb = try #require(RGBColor(uiColor: surface.resolvedColor(with: traits)))
                        #expect(roles.text.contrast(with: rgb) >= target)
                    }
                    #expect(RGBColor(uiColor: AccentRole.text.uiColor.resolvedColor(with: traits)) == roles.text)
                    #expect(RGBColor(uiColor: AccentRole.fill.uiColor.resolvedColor(with: traits)) == roles.fill)
                    #expect(RGBColor(uiColor: AccentRole.onFill.uiColor.resolvedColor(with: traits)) == roles.onFill)
                    #expect(RGBColor(uiColor: AccentRole.selectedSurface.uiColor.resolvedColor(with: traits)) == roles.selectedSurface)
                    #expect(roles.fill.contrast(with: roles.onFill) >= target)
                }
            }
        }
    }

    @Test("SwiftUI profile accent crosses into native views and changes without replacing them")
    func environmentBridge() async throws {
        let probe = UIView()
        probe.tintColor = AccentRole.text.uiColor
        let controller = UIHostingController(
            rootView: NativeAccentProbe(view: probe)
                .environment(\.personalAccent, PersonalAccent(savedHex: "#FACC15"))
        )
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<100 {
            if probe.traitCollection[PersonalAccentTrait.self].savedHex == "#FACC15" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.traitCollection[PersonalAccentTrait.self].savedHex == "#FACC15")
        controller.rootView = NativeAccentProbe(view: probe)
            .environment(\.personalAccent, PersonalAccent(savedHex: "#FF00FF"))
        for _ in 0..<100 {
            if probe.traitCollection[PersonalAccentTrait.self].savedHex == "#FF00FF" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.traitCollection[PersonalAccentTrait.self].savedHex == "#FF00FF")
        #expect(probe.window === window)
    }
}

private struct NativeAccentProbe: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
