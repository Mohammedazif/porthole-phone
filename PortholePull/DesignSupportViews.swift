import Accessibility
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SaveFolderPicker: UIViewControllerRepresentable {
    let completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}

struct ClipboardHistorySheet: View {
    let item: ActivityRecord
    @ObservedObject var client: PullClient
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        Text(item.clipboardText ?? item.title)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    }
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(item.date, style: .date)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if client.canCopy(item) {
                        GlassCapsuleButton(title: copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc", prominent: true) {
                            client.copyActivity(item) { success in
                                copied = success
                                AccessibilityNotification.Announcement(success ? "Copied to this iPhone." : client.activityMessage).post()
                            }
                        }
                        GlassCapsuleButton(title: "Send to PC", systemImage: "arrow.up") { client.sendActivity(item) }
                            .disabled(!client.linked || !client.clipboardSyncEnabled)
                        if copied {
                            Text("Copied to this iPhone. Ready to paste.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("The full content of this item is unavailable. Older app versions kept only a summary; newer items keep their text or image for copying again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Clipboard item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close") }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: item.id) {
            guard let url = client.clipboardPreviewURL(item) else { return }
            let thumbnail = await FileThumb.image(url: url, maxPixelSize: 960)
            if !Task.isCancelled { image = thumbnail }
        }
    }
}

struct SendFilePicker: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: ([URL]) -> Void
        init(completion: @escaping ([URL]) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion([]) }
    }
}

/// Photo Library or Files, as the person starts a send.
struct SendChoiceSheet: View {
    let peerName: String
    let choose: (SendSource) -> Void

    enum SendSource { case photoLibrary, files }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    row("Photo Library", "Photos and videos", systemImage: "photo.on.rectangle", tint: .orange) {
                        choose(.photoLibrary)
                    }
                    Divider().padding(.leading, 74)
                    row("Files", "Documents and other files", systemImage: "folder.fill", tint: .blue) {
                        choose(.files)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Sending continues if you leave Porthole.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Send to PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Send to PC").font(.headline)
                        Text(peerName).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .presentationDetents([.height(300)])
    }

    private func row(_ title: String, _ detail: String, systemImage: String, tint: Color,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The system photo picker, giving Porthole each item's place in the
/// library so it can be sent from there.
struct SendPhotoPicker: UIViewControllerRepresentable {
    let completion: ([SendPick]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = TransferStaging.maxItems
        configuration.preferredAssetRepresentationMode = .current
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([SendPick]) -> Void
        init(completion: @escaping ([SendPick]) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            completion(results.map { .photo(identifier: $0.assetIdentifier, provider: $0.itemProvider) })
        }
    }
}

struct SendFilesSheet: View {
    @ObservedObject var sender: OutboundFileSender
    @ObservedObject var client: PullClient
    let peer: TrustedPeer
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false

    private var remaining: Int { sender.items.filter { !$0.sent }.count }
    private var reviewingConnectedPeer: Bool {
        guard let connected = client.fileSendPeer else { return false }
        return connected.samePairing(as: peer) && connected.resumable
    }
    private var peerName: String { peer.name.isEmpty ? peer.host : peer.name }

    private var transferAvailability: String {
        if let connected = client.fileSendPeer {
            if !connected.samePairing(as: peer) { return "To send to another PC, close this and choose again." }
            return "Waiting for \(peerName)."
        }
        return "Connect to \(peerName) to continue."
    }

    private var canSend: Bool {
        reviewingConnectedPeer && remaining > 0 && [.ready, .failed, .cancelled].contains(sender.phase)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    if sender.phase == .preparing {
                        ProgressView(sender.message.isEmpty ? "Preparing…" : sender.message)
                            .frame(maxWidth: .infinity)
                            .padding(25)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(sender.items) { item in
                            row(item)
                            if item.id != sender.items.last?.id { Divider().padding(.leading, 70) }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if (sender.phase == .failed || sender.phase == .cancelled) && !sender.message.isEmpty {
                        Text(sender.message).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !reviewingConnectedPeer, sender.phase != .sent {
                        Text(transferAvailability).font(.footnote).foregroundStyle(.secondary)
                    } else if sender.phase == .sending {
                        Text("You can leave Porthole. Progress appears on the Lock Screen.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) { transferActions }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(sender.phase == .sending ? "Sending" : sender.phase == .sent ? "Sent" : "Send to PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sender.phase == .sent ? "Done" : "Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .confirmationDialog("Cancel sending?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Cancel Sending", role: .destructive) {
                sender.discardPending()
                dismiss()
            }
            Button("Keep Sending", role: .cancel) { }
        } message: {
            Text("Items already sent stay on \(peerName).")
        }
        .onChange(of: sender.phase) { _, phase in
            switch phase {
            case .sent: AccessibilityNotification.Announcement("Sent to \(peerName)").post()
            case .failed, .cancelled:
                if !sender.message.isEmpty { AccessibilityNotification.Announcement(sender.message).post() }
            default: break
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 40, height: 40)
                    .background(Color(.label), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("To").font(.footnote).foregroundStyle(.secondary)
                    Text(peerName).font(.body.weight(.semibold))
                }
            }
            if sender.phase == .sending || sender.phase == .sent {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(bytes(sender.sentBytes)) ")
                        .font(.system(.title, design: .monospaced).weight(.medium))
                    + Text("of \(bytes(sender.totalBytes))")
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((sender.progress * 100).rounded()))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                ProgressView(value: sender.progress)
                    .tint(.primary)
                    .accessibilityLabel("Sent")
                if sender.phase == .sending, let left = sender.secondsLeft {
                    Text(Self.remaining(left)).font(.subheadline).foregroundStyle(.secondary)
                }
            } else if !sender.items.isEmpty {
                Text("\(sender.items.count) \(sender.items.count == 1 ? "item" : "items") · \(bytes(sender.items.reduce(0) { $0 + $1.bytes }))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row(_ item: OutboundFileSender.Item) -> some View {
        HStack(spacing: 12) {
            TransferThumbnailView(source: item.source, url: item.url, name: item.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status(item))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(item.sent ? Color.green : item.id == sender.activeItemID ? Color.primary : Color.secondary)
            }
            Spacer(minLength: 8)
            Text(bytes(item.bytes))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func status(_ item: OutboundFileSender.Item) -> String {
        if item.sent { return "Sent" }
        if item.id == sender.activeItemID { return "Sending… \(Int((sender.activeFraction * 100).rounded()))%" }
        if sender.phase == .sending { return "Waiting" }
        return "Ready"
    }

    private var transferActions: some View {
        VStack(spacing: 12) {
            if sender.phase == .sent {
                GlassCapsuleButton(title: "Done", systemImage: "checkmark", prominent: true) { dismiss() }
            } else if sender.phase == .sending {
                HStack(spacing: 10) {
                    GlassCapsuleButton(title: "Pause", systemImage: "pause.fill") { sender.pause() }
                    GlassCapsuleButton(title: "Cancel", tint: .red) { confirmingDiscard = true }
                }
            } else if remaining > 0, sender.phase != .preparing {
                let started = sender.items.contains(where: \.sent) || sender.phase == .failed || sender.phase == .cancelled
                GlassCapsuleButton(title: started ? "Continue Sending" : "Send \(remaining) \(remaining == 1 ? "Item" : "Items")",
                                   systemImage: "arrow.up", prominent: true) {
                    guard reviewingConnectedPeer else { return }
                    sender.send(to: peer) { client.importSentReceipts() }
                }
                .disabled(!canSend)
                if started {
                    Button("Cancel Sending", role: .destructive) { confirmingDiscard = true }
                        .font(.footnote)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func remaining(_ seconds: Double) -> String {
        if seconds < 60 { return "Less than a minute remaining" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "About \(minutes) \(minutes == 1 ? "minute" : "minutes") remaining" }
        let hours = Double(minutes) / 60
        return String(format: "About %.1f hours remaining", hours)
    }
}
