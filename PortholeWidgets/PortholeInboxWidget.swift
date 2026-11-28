import SwiftUI
import WidgetKit
import UIKit

struct PortholeInboxEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetInboxSnapshot
}

struct PortholeInboxProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortholeInboxEntry {
        PortholeInboxEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (PortholeInboxEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : (WidgetInboxStore.shared()?.load() ?? WidgetInboxSnapshot())
        completion(PortholeInboxEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortholeInboxEntry>) -> Void) {
        let now = Date()
        guard let snapshot = WidgetInboxStore.shared()?.load() else {
            let entry = PortholeInboxEntry(date: now, snapshot: WidgetInboxSnapshot())
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(3_600))))
            return
        }
        var entries = [PortholeInboxEntry(date: now, snapshot: snapshot)]
        if let expiration = snapshot.transfer?.expiresAt, expiration > now {
            entries.append(PortholeInboxEntry(date: expiration, snapshot: snapshot))
        }
        // Periodic reconciliation also recovers when the app exits before requesting a reload.
        let refresh = entries.count > 1 ? entries[1].date : now.addingTimeInterval(1_800)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

@main
struct PortholeWidgets: WidgetBundle {
    var body: some Widget {
        PortholeInboxWidget()
        TransferLiveActivityWidget()
    }
}

struct PortholeInboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetInboxSnapshot.kind, provider: PortholeInboxProvider()) { entry in
            PortholeInboxWidgetView(entry: entry)
        }
        .configurationDisplayName("Porthole")
        .description("See new PC files and open Porthole’s sharing, file, and clipboard controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

private struct PortholeInboxWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.redactionReasons) private var redactionReasons

    let entry: PortholeInboxEntry

    private var isAccessory: Bool {
        family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular
    }

    private var summary: WidgetInboxSummary {
        entry.snapshot.summary(at: entry.date, redacted: redactionReasons.contains(.privacy))
    }

    private var hidesDetails: Bool { summary == .privateReceived }

    private var destination: WidgetDestination { family == .accessoryCircular ? .connect : summary.destination }

    var body: some View {
        layout
            .widgetURL(destination.url)
            .containerBackground(for: .widget) {
                if isAccessory {
                    Color.clear
                } else {
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(uiColor: .secondarySystemGroupedBackground), Color(uiColor: .systemGroupedBackground)]
                            : [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemGroupedBackground)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
    }

    @ViewBuilder
    private var layout: some View {
        switch family {
        case .accessoryInline:
            Label(inlineTitle, systemImage: inlineSymbol)
                .privacySensitive(!hidesDetails)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    mark(size: 26)
                    Text(pairingTitle)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .privacySensitive(!hidesDetails)
                }
            }
            .accessibilityElement(children: .combine)
        case .accessoryRectangular:
            HStack(spacing: 7) {
                Image(systemName: summarySymbol)
                    .font(.title3)
                    .widgetAccentable()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Porthole")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .privacySensitive(!hidesDetails)
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var inlineTitle: String {
        switch summary {
        case .unread(let count): return "\(WidgetInboxSummary.displayCount(count)) new"
        case .pair: return "Pair Porthole"
        case .receiving: return "Transfer started"
        case .transferStatusUnknown: return "View transfer"
        case .transferNeedsAttention: return "Check transfer"
        default: return "Porthole"
        }
    }

    private var inlineSymbol: String {
        switch summary {
        case .open, .privateReceived, .empty, .caughtUp: return "tray"
        default: return summarySymbol
        }
    }

    private var summarySymbol: String {
        switch summary {
        case .unread: return "tray.and.arrow.down"
        case .pair: return "qrcode"
        case .receiving: return "arrow.down.circle"
        case .transferNeedsAttention: return "exclamationmark.circle"
        case .privateReceived, .empty, .caughtUp: return "tray"
        case .transferStatusUnknown: return "arrow.down.circle"
        case .open: return "circle"
        }
    }

    private var pairingTitle: String {
        if hidesDetails || entry.snapshot.pairing == .unknown { return "Open" }
        return entry.snapshot.isPaired ? "Paired" : "Pair PC"
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            mark(size: 31)
            Spacer(minLength: 2)
            if case .unread(let count) = summary {
                Text(WidgetInboxSummary.displayCount(count))
                    .font(.system(size: 38, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .accessibilityHidden(true)
                Text(count == 1 ? "new file" : "new files")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityHidden(true)
            } else {
                Text(summary.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 2)
            actionLabel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.title), \(summary.action)")
        .privacySensitive(!hidesDetails)
    }

    private var medium: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    mark(size: 21)
                    Text("Porthole").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 1)
                Text(summary.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                actionLabel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .privacySensitive(!hidesDetails)

            ViewThatFits(in: .vertical) {
                VStack(spacing: 4) {
                    shortcut("Share screen", symbol: "rectangle.on.rectangle", destination: .share)
                    shortcut("Send files", symbol: "doc", destination: .send)
                    shortcut("Clipboard", symbol: "clipboard", destination: .clipboard)
                }
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        shortcut("Share screen", symbol: "rectangle.on.rectangle", destination: .share, compact: "Share")
                        shortcut("Send files", symbol: "doc", destination: .send, compact: "Send")
                    }
                    shortcut("Clipboard", symbol: "clipboard", destination: .clipboard)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actionLabel: some View {
        Label(summary.action, systemImage: "arrow.up.right")
            .labelStyle(TrailingWidgetSymbolStyle())
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func mark(size: CGFloat) -> some View {
        Image("PortholeWidgetMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .widgetAccentable()
            .accessibilityHidden(true)
    }

    private func shortcut(_ title: String, symbol: String, destination: WidgetDestination, compact: String? = nil) -> some View {
        Link(destination: destination.url) {
            let layout = compact == nil ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 2))
            layout {
                Image(systemName: symbol).widgetAccentable().accessibilityHidden(true)
                Text(compact ?? title).lineLimit(1).minimumScaleFactor(0.65)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact == nil ? 7 : 4)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, maxHeight: .infinity,
                   alignment: compact == nil ? .leading : .center)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(renderingMode == .fullColor ? Color(uiColor: .tertiarySystemFill) : Color.primary.opacity(0.12))
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}

private struct TrailingWidgetSymbolStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.accessibilityHidden(true)
        }
    }
}
