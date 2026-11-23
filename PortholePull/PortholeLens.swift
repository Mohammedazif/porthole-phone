import SwiftUI

/// The sharing control uses the approved thin-rim UI variant of the brand mark.
/// Keep the rim, cursor clearance and reflections together in the vector asset.
struct PortholeLens<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let diameter: CGFloat
    private let content: Content

    init(diameter: CGFloat, @ViewBuilder content: () -> Content) {
        self.diameter = diameter
        self.content = content()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: colorScheme == .dark
                        ? [Color(white: 0.18), Color(white: 0.09)]
                        : [.white, Color(white: 0.98)],
                    center: UnitPoint(x: 0.35, y: 0.25),
                    startRadius: 0,
                    endRadius: diameter * 0.7
                ))
                // The vector's rim is centered on a radius of 180 in a 380 pt canvas.
                .padding(diameter * 10 / 380)
                .accessibilityHidden(true)

            Image("PortholeShareMark")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .accessibilityHidden(true)

            content
                .frame(width: diameter * 0.66, height: diameter * 0.56)
                .offset(y: -diameter * 0.025)
        }
        .frame(width: diameter, height: diameter)
    }
}
