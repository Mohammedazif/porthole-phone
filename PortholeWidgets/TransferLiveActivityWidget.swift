import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// A file transfer on the Lock Screen, in Notification Center and in the
/// Dynamic Island: Porthole's direction, the file and how far it is, a ring
/// with the progress, and Stop.
struct TransferLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.attributes.incoming ? "arrow.down" : "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.white.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                StopRing(fraction: context.state.fraction, incoming: context.attributes.incoming, size: 40)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StopRing(fraction: context.state.fraction, incoming: context.attributes.incoming, size: 34)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } compactLeading: {
                Image(systemName: context.attributes.incoming ? "arrow.down" : "arrow.up")
                    .accessibilityHidden(true)
            } compactTrailing: {
                Ring(fraction: context.state.fraction, size: 18)
            } minimal: {
                Ring(fraction: context.state.fraction, size: 18)
            }
        }
    }
}

/// How far it is, as a ring.
private struct Ring: View {
    let fraction: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: size / 9)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(.white, style: StrokeStyle(lineWidth: size / 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent")
    }
}

/// The ring with Stop in the middle, as iOS's own transfers show it.
private struct StopRing: View {
    let fraction: Double
    let incoming: Bool
    let size: CGFloat

    var body: some View {
        Button(intent: StopTransferIntent(incoming: incoming)) {
            ZStack {
                Ring(fraction: fraction, size: size)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: size / 4, height: size / 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(incoming ? "Stop receiving" : "Stop sending")
    }
}
