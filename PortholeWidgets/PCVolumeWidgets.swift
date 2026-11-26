import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Dynamic Island (and Lock Screen) buttons for the PC's volume, while the
/// iPhone's sound plays on the PC. Long-press the island for the buttons.
struct PortholeSoundLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PortholeSoundAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sound on \(context.state.pcName)")
                        .font(.headline)
                        .lineLimit(1)
                    Text("PC volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                PCVolumeButtons()
            }
            .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("PC", systemImage: "speaker.wave.2.fill")
                        .font(.headline)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PCVolumeButtons()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Sound on \(context.state.pcName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "speaker.wave.2.fill")
            } compactTrailing: {
                Text("PC")
                    .font(.caption.weight(.semibold))
            } minimal: {
                Image(systemName: "speaker.wave.2.fill")
            }
        }
    }
}

private struct PCVolumeButtons: View {
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: PCVolumeIntent(louder: false)) {
                Image(systemName: "minus")
                    .font(.headline)
                    .frame(width: 44, height: 36)
            }
            .accessibilityLabel("PC volume down")
            Button(intent: PCVolumeIntent(louder: true)) {
                Image(systemName: "plus")
                    .font(.headline)
                    .frame(width: 44, height: 36)
            }
            .accessibilityLabel("PC volume up")
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }
}

/// Control Center buttons: add them from the Control Center editor.
@available(iOS 18.0, *)
struct PCVolumeDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.porthole.pull.pc-volume-down") {
            ControlWidgetButton(action: PCVolumeIntent(louder: false)) {
                Label("PC Volume Down", systemImage: "speaker.wave.1.fill")
            }
        }
        .displayName("PC Volume Down")
        .description("Turns the PC's volume down while Porthole is connected.")
    }
}

@available(iOS 18.0, *)
struct PCVolumeUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.porthole.pull.pc-volume-up") {
            ControlWidgetButton(action: PCVolumeIntent(louder: true)) {
                Label("PC Volume Up", systemImage: "speaker.wave.3.fill")
            }
        }
        .displayName("PC Volume Up")
        .description("Turns the PC's volume up while Porthole is connected.")
    }
}

@main
struct PortholeWidgetBundle: WidgetBundle {
    var body: some Widget {
        PortholeInboxWidget()
        PortholeSoundLiveActivity()
        if #available(iOS 18.0, *) {
            PCVolumeDownControl()
            PCVolumeUpControl()
        }
    }
}
