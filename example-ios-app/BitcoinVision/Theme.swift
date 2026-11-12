import SwiftUI
import UIKit

// Paper, ink, graphite and one pen: the app is the digital half of a paper
// worksheet, so it keeps the worksheet's colours rather than the system's.
// The same palette as the Android app's Theme.kt, by role.

private func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
}

/** The app's colour roles, named as Material names them on Android. */
enum Palette {
    static let primary = dynamic(0x2447A0, 0x9DB4F2)
    static let onPrimary = dynamic(0xFFFFFF, 0x0E1F4D)
    static let primaryContainer = dynamic(0xDCE4F7, 0x1F3574)
    static let onPrimaryContainer = dynamic(0x14295E, 0xDCE4F7)
    static let secondary = dynamic(0x5C5F63, 0xB0B2B6)
    static let secondaryContainer = dynamic(0xF1F1EF, 0x2C2D31)
    static let onSecondaryContainer = dynamic(0x17181A, 0xECECEA)
    static let background = dynamic(0xF7F7F5, 0x131315)
    static let onBackground = dynamic(0x17181A, 0xECECEA)
    static let surface = dynamic(0xFFFFFF, 0x131315)
    static let onSurface = dynamic(0x17181A, 0xECECEA)
    static let surfaceVariant = dynamic(0xF1F1EF, 0x26272B)
    static let onSurfaceVariant = dynamic(0x5C5F63, 0xB0B2B6)
    static let surfaceContainerLow = dynamic(0xF7F7F5, 0x18181B)
    static let surfaceContainer = dynamic(0xF1F1EF, 0x1C1C1F)
    static let surfaceContainerHigh = dynamic(0xEAEAE7, 0x232427)
    static let surfaceContainerHighest = dynamic(0xE3E3E0, 0x2C2D31)
    static let outline = dynamic(0x73767A, 0x8A8D91)
    static let outlineVariant = dynamic(0xD9DAD6, 0x34363A)
    static let error = dynamic(0xB3261E, 0xF2B8B5)
    static let onError = dynamic(0xFFFFFF, 0x601410)
    static let errorContainer = dynamic(0xF9DEDC, 0x8C1D18)
    static let onErrorContainer = dynamic(0x410E0B, 0xF9DEDC)

    /** White camera instructions retain contrast even over a white preview. */
    static let cameraScrim = Color.black.opacity(0.65)
}

/** The worksheet's face (IBM Plex Mono) and its sans companion for prose. */
enum Typeface {
    static let monoName = "IBMPlexMono-Regular"

    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(monoName, size: size, relativeTo: style)
    }

    /** The variable sans font's named instances; the app uses two weights, as Android's Theme.kt does. */
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .medium: name = "IBMPlexSans-Medium"
        case .semibold: name = "IBMPlexSans-SemiBold"
        case .bold, .heavy, .black: name = "IBMPlexSans-Bold"
        default: name = "IBMPlexSans-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }
}

/** Material 3's type scale in the app's faces, by Material's role names. */
extension Font {
    static let displayLarge = Typeface.mono(57, relativeTo: .largeTitle)
    static let displayMedium = Typeface.mono(45, relativeTo: .largeTitle)
    static let displaySmall = Typeface.mono(36, relativeTo: .largeTitle)
    static let headlineLarge = Typeface.sans(32, weight: .medium, relativeTo: .title)
    static let headlineMedium = Typeface.sans(28, weight: .medium, relativeTo: .title)
    static let headlineSmall = Typeface.sans(24, weight: .medium, relativeTo: .title2)
    static let titleLarge = Typeface.sans(22, weight: .medium, relativeTo: .title3)
    static let titleMedium = Typeface.sans(16, weight: .medium, relativeTo: .headline)
    static let titleSmall = Typeface.sans(14, weight: .medium, relativeTo: .subheadline)
    static let bodyLarge = Typeface.sans(16, relativeTo: .body)
    static let bodyMedium = Typeface.sans(14, relativeTo: .callout)
    static let bodySmall = Typeface.sans(12, relativeTo: .footnote)
    static let labelLarge = Typeface.sans(14, weight: .medium, relativeTo: .subheadline)
    static let labelMedium = Typeface.sans(12, weight: .medium, relativeTo: .caption)
    static let labelSmall = Typeface.sans(11, weight: .medium, relativeTo: .caption2)
    /** A written word, as the worksheet prints it. */
    static let word = Typeface.mono(16, relativeTo: .body)
}

/**
 * The app's one motion vocabulary. State changes settle on a spring with no
 * overshoot; SwiftUI already honours Reduce Motion for navigation pushes.
 */
enum Motion {
    static let state = Animation.spring(response: 0.35, dampingFraction: 1)
}

/** A filled button in the pen colour: the page's one main action. */
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.labelLarge)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .foregroundStyle(enabled ? Palette.onPrimary : Palette.onSurface.opacity(0.38))
            .background(
                Capsule().fill(enabled ? Palette.primary : Palette.onSurface.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/** A quiet button: text in the pen colour, for the page's lesser actions. */
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.labelLarge)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .foregroundStyle(enabled ? Palette.primary : Palette.onSurface.opacity(0.38))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/** An outlined button: an alternative weighed beside the main action. */
struct OutlinedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.labelLarge)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .foregroundStyle(enabled ? Palette.primary : Palette.onSurface.opacity(0.38))
            .overlay(Capsule().stroke(enabled ? Palette.outline : Palette.onSurface.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == OutlinedButtonStyle {
    static var outlined: OutlinedButtonStyle { OutlinedButtonStyle() }
}
