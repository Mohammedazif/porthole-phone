import Accessibility
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

    private var transferAvailability: String {
        if let connected = client.fileSendPeer {
            if !connected.samePairing(as: peer) { return "To send to another PC, close this transfer and select your files again." }
            return "Waiting for the PC to confirm file transfer support."
        }
        return "Reconnect to the reviewed PC to retry unsent files."
    }

    private var canSend: Bool {
        reviewingConnectedPeer && remaining > 0 && [.ready, .failed, .cancelled].contains(sender.phase)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Send to")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(peer.name.isEmpty ? peer.host : peer.name)
                            .font(.title2.bold())
                        Text(peer.host).font(.footnote).foregroundStyle(.secondary)
                    }
                    if sender.phase == .preparing {
                        ProgressView("Preparing files…").frame(maxWidth: .infinity).padding(25)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(sender.items) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "doc")
                                    .font(.title3)
                                    .frame(width: 32)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.subheadline.weight(.medium))
                                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if item.sent {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("Saved on PC")
                                }
                            }
                            .padding(16)
                            .accessibilityElement(children: .combine)
                            if item.id != sender.items.last?.id { Divider().padding(.leading, 16) }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                    if !sender.message.isEmpty {
                        Text(sender.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !reviewingConnectedPeer, sender.phase != .sent {
                        Text(transferAvailability)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) { transferActions }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Send files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sender.phase == .sent ? "Close" : "Cancel") {
                        if sender.phase != .sent { sender.cancel() }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(sender.phase == .sending)
        .confirmationDialog("Discard this transfer?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard remaining files", role: .destructive) {
                sender.discardPending()
                dismiss()
            }
            Button("Keep transfer", role: .cancel) { }
        } message: {
            Text("Porthole removes its prepared copies. Files already saved on the PC and your source files stay available.")
        }
        .onChange(of: sender.phase) { _, phase in
            switch phase {
            case .ready, .sending, .sent, .failed, .cancelled:
                if !sender.message.isEmpty { AccessibilityNotification.Announcement(sender.message).post() }
            default: break
            }
        }
    }

    private var transferActions: some View {
        VStack(spacing: 12) {
            if sender.phase == .sending || sender.phase == .sent {
                ProgressView("Transfer progress", value: sender.progress)
                    .tint(.primary)
            }
            if sender.phase == .sent {
                GlassCapsuleButton(title: "Done", systemImage: "checkmark", prominent: true) { dismiss() }
            } else if sender.phase == .sending {
                GlassCapsuleButton(title: "Cancel transfer", tint: .red) { sender.cancel() }
            } else if remaining > 0, sender.phase != .preparing {
                GlassCapsuleButton(title: sender.phase == .ready ? "Send \(remaining) \(remaining == 1 ? "file" : "files")" : "Retry unsent files",
                                   systemImage: "square.and.arrow.up", prominent: true) {
                    guard reviewingConnectedPeer else { return }
                    sender.send(to: peer) { client.importSentReceipts() }
                }
                .disabled(!canSend)
                Button("Discard pending transfer", role: .destructive) { confirmingDiscard = true }
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}
