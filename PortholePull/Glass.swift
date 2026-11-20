import SwiftUI
import UIKit

/// Ink for the main action: near-black in light mode, white in dark mode, so the button
/// never sinks into the background. onInk is the text on it.
enum Ink {
    static let fill = Color(UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(white: 0.07, alpha: 1) })
    static let onFill = Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
}

// Liquid Glass on iOS 26, built with Xcode 26 or later. Older systems and older Xcode
// builds get the frosted look Porthole had before, so the app still runs from iOS 17.

/// A capsule button: glass, or prominent ink glass for the main action on a screen.
struct GlassCapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent = false
    var tint: Color? = nil
    var expands = true
    let action: () -> Void

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent {
                Button(action: action) { label.foregroundStyle(tint == nil ? Ink.onFill : Color.white) }
                    .buttonStyle(.glassProminent)
                    .tint(tint ?? Ink.fill)
                    .controlSize(.large)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.glass)
                    .tint(tint)
                    .controlSize(.large)
            }
        } else {
            frosted
        }
        #else
        frosted
        #endif
    }

    private var label: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(.headline)
        .frame(maxWidth: expands ? .infinity : nil)
        .padding(.vertical, 4)
    }

    private var frosted: some View {
        Button(action: action) {
            label
                .padding(.vertical, 8)
                .padding(.horizontal, expands ? 0 : 16)
                .foregroundStyle(prominent ? (tint == nil ? Ink.onFill : Color.white) : (tint ?? Color.primary))
                .background {
                    if prominent {
                        Capsule().fill((tint ?? Ink.fill).opacity(0.92))
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
                .overlay { Capsule().strokeBorder(.white.opacity(prominent ? 0.25 : 0.7), lineWidth: 1) }
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

/// A round glass button holding one symbol, such as Back or Switch PC.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Button(action: action) { symbol }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel(label)
        } else {
            frosted
        }
        #else
        frosted
        #endif
    }

    private var symbol: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .frame(width: 22, height: 22)
    }

    private var frosted: some View {
        Button(action: action) {
            symbol
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A floating glass surface, such as the banner for a file that arrived.
struct GlassPanel<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
        #else
        content.background(.regularMaterial, in: shape)
        #endif
    }
}

/// The Share screen lens: dark glass on iOS 26.
struct LensGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Not .interactive(): an interactive glass layer takes the tap the button needs.
            content.glassEffect(.regular.tint(.black.opacity(0.6)), in: Circle())
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func glassPanel<S: Shape>(_ shape: S) -> some View {
        modifier(GlassPanel(shape: shape))
    }
}
