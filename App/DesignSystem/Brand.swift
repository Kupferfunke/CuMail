import SwiftUI
import AppKit
import CoreText
import MailDomain

// SDK 27 exports a second @State macro; CLT omits that plugin. This alias explicitly
// selects the stable macOS-14-compatible property wrapper, also supported in Xcode.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Notification.Name {
    static let focusMailSearch = Notification.Name("MikeMailHub.focusSearch")
    static let signaturesDidChange = Notification.Name("CuMail.signaturesDidChange")
    static let localDraftsDidChange = Notification.Name("CuMail.localDraftsDidChange")
    static let mailSubmissionDidComplete = Notification.Name("CuMail.mailSubmissionDidComplete")
}

enum AppResources {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }
    static func url(_ name: String, extension ext: String, folder: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: folder)
    }
    @MainActor static func registerFonts() {
        for name in ["JosefinSans-Bold", "Barlow-Bold", "IBMPlexMono-Regular"] {
            if let url = url(name, extension: "ttf", folder: "Fonts") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
}

enum Brand {
    static let copper = Color(hex: 0xA54D1B)
    static let copperDark = Color(hex: 0x743111)
    static let copperLight = Color(hex: 0xC26A35)
    static let ink = Color(hex: 0x182225)
    static let inkSoft = Color(hex: 0x303A3C)
    static let paper = Color(hex: 0xF3EEE5)
    static let paperDeep = Color(hex: 0xE7DED1)
    static let spark = Color(hex: 0xF9D09C)
    static let muted = Color(hex: 0x626762)
    static let line = Color(hex: 0xB8B7AE)
    static func canvas(_ scheme: ColorScheme) -> Color { scheme == .dark ? ink : paper }
    static func toolbar(_ scheme: ColorScheme) -> Color { scheme == .dark ? inkSoft : paperDeep }
    static func surface(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x202C2F) : Color(hex: 0xFFFCF7) }
    static func text(_ scheme: ColorScheme) -> Color { scheme == .dark ? paper : ink }
    static func secondary(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0xC3C8C2) : muted }
    static func accent(_ scheme: ColorScheme) -> Color { scheme == .dark ? spark : copper }
    static func selection(_ scheme: ColorScheme) -> Color { scheme == .dark ? inkSoft : paperDeep }
    static func selectionAccent(_ scheme: ColorScheme) -> Color { scheme == .dark ? spark : copperDark }
    static func headline(_ size: CGFloat) -> Font { .custom("Barlow-Bold", size: size) }
    static func mono(_ size: CGFloat = 10) -> Font { .custom("IBMPlexMono-Regular", size: size) }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

struct BrandLockup: View {
    var dark = false
    var width: CGFloat = 176
    var body: some View {
        if let url = AppResources.url(dark ? "LockupDark" : "LockupLight", extension: "pdf", folder: "Brand"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: width).accessibilityLabel("KupferFunke")
        } else {
            // The supplied static 700 instance retains its original PostScript name.
            Text("KupferFunke").font(.custom("JosefinSans-Thin", size: 23)).foregroundStyle(dark ? Brand.paper : Brand.ink)
        }
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(Brand.mono()).tracking(1.5).textCase(.uppercase) }
}

/// Small account identities in the sidebar; independent of the application icon.
struct AccountSymbol: View {
    let account: MailAccount
    var onDarkBackground = true

    private var identity: (symbol: String, color: Color) {
        switch account.address.value.split(separator: "@").last?.lowercased() {
        case "kupferfunke.ch": ("wrench.and.screwdriver", onDarkBackground ? Brand.spark : Color(hex: 0xA65025))
        case "senseoftime.ch": ("hourglass", Color(hex: onDarkBackground ? 0xD5B47B : 0x8B6226))
        case "padelvision.ch": ("eyeglasses", Color(hex: onDarkBackground ? 0x78C8BA : 0x26766D))
        default: account.provider == .gmail
            ? ("envelope", Color(hex: onDarkBackground ? 0xEF9B8F : 0xAB4B3B))
            : ("envelope", Color(hex: onDarkBackground ? 0x9EBBCC : 0x486E84))
        }
    }

    var body: some View {
        Image(systemName: identity.symbol)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(identity.color)
            .frame(width: 22, height: 24)
            .accessibilityHidden(true)
    }
}

/// A small, native wordmark; the Dock and Finder icon remain unchanged.
struct CuMailWordmark: View {
    var size: CGFloat = 32
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Cu").foregroundStyle(LinearGradient(colors: [Brand.spark, Brand.copper], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Mail").foregroundStyle(Brand.paper)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "sparkle").font(.system(size: size * 0.28)).foregroundStyle(Brand.spark)
                        .offset(x: 9, y: -2).accessibilityHidden(true)
                }
        }.font(.system(size: size, weight: .semibold, design: .rounded)).tracking(-0.7)
            .accessibilityElement(children: .ignore).accessibilityLabel("CuMail by KupferFunke")
    }
}

struct CuMailBrandArtwork: View {
    var body: some View {
        if let url = AppResources.url("CuMail", extension: "png", folder: "Brand"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("CuMail by KupferFunke")
        }
    }
}
