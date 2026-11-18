// Content of Tapper's welcome guide (five pages). Text is localised via
// Localizable.strings ("onboarding.tapper.*"); images are in Resources/Onboarding.

import AppKit
import SwiftUI

enum TapperGuide {
    static var ctaTitle: String { L("Show pointer") }

    static func pages() -> [OnboardingPage] {
        func key(_ n: Int, _ part: String) -> String { "onboarding.tapper.p\(n).\(part)" }
        func page(_ n: Int, _ art: AnyView, extra: AnyView? = nil) -> OnboardingPage {
            OnboardingPage(id: n, title: L(key(n, "title")), body: L(key(n, "body")), art: art, extra: extra)
        }
        return [
            page(1, AnyView(ShotImage(name: "hero"))),
            page(2, AnyView(shortcutArt(image: "idle", keys: ["⌃", "⌥", "P"], label: L("onboarding.tapper.p2.tag")))),
            page(3, AnyView(ShotImage(name: "hit"))),
            page(4, AnyView(menuArt)),
            page(5, AnyView(shortcutArt(image: "middle", keys: ["⌃", "⌥", "T"], label: L("Presentation mode"))),
                 extra: AnyView(Button(L("Open Accessibility Settings")) { openAccessibilitySettings() }
                    .buttonStyle(GuideButtonStyle()))),
        ]
    }

    /// Opens System Settings → Privacy & Security → Accessibility (only when the user clicks the button).
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // Pages 2 and 5: an existing still with the global shortcut shown on top.
    private static func shortcutArt(image: String, keys: [String], label: String) -> some View {
        ZStack(alignment: .bottom) {
            ShotImage(name: image).frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 8) {
                KeyCaps(keys: keys, size: 38)
                Tag(text: label)
            }
            .padding(.bottom, 18)
        }
    }

    // Page 4: the menu (drawn from the real menu strings) next to the Cat paw still.
    private static var menuArt: some View {
        HStack(spacing: 16) {
            MenuMock(rows: [
                .item(L("Hide pointer"), trailing: "⌃⌥P"),
                .item(L("Presentation mode"), trailing: "⌃⌥T"),
                .separator,
                .slider(title: L("Pointer mood"), left: L("Shy finger"), right: L("In your face"), value: 0.25),
                .item(L("Tiny hand"), checked: true),
                .item(L("Cat paw")),
                .item(L("Middle child")),
                .separator,
                .item(L("Color"), trailing: "›"),
                .separator,
                .item(L("Animate on click"), checked: true),
                .item(L("Knock sound"), checked: true),
            ], width: 250)
            ShotImage(name: "paw")
                .frame(width: 270, height: 169)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
