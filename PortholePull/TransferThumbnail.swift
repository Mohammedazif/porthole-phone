import Photos
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// The thumbnail iOS shows for an item being sent: the photo, a video's
/// frame, a document's first page. Nil when iOS has none; Porthole then
/// shows its file-type icon.
enum TransferThumbnail {
    static func image(for source: TransferSource, url: URL, side: CGFloat) async -> UIImage? {
        let size = CGSize(width: side, height: side)
        switch source {
        case .photo(let identifier, _):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
            return await photo(asset, size: size)
        case .file(let bookmark):
            var stale = false
            guard let original = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                          bookmarkDataIsStale: &stale) else { return nil }
            let scoped = original.startAccessingSecurityScopedResource()
            defer { if scoped { original.stopAccessingSecurityScopedResource() } }
            return await file(original, size: size)
        case .staged:
            return await file(url, size: size)
        }
    }

    /// A video's length, for the badge on its thumbnail.
    static func duration(for source: TransferSource) -> TimeInterval? {
        guard case .photo(let identifier, _) = source,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.mediaType == .video else { return nil }
        return asset.duration
    }

    static func file(_ url: URL, size: CGSize) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: UIScreen.main.scale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }

    private static func photo(_ asset: PHAsset, size: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = UIScreen.main.scale
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFill,
                                                  options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// A small JPEG for a notification's attachment.
    static func attachmentFile(for source: TransferSource, url: URL) async -> URL? {
        guard let image = await image(for: source, url: url, side: 120),
              let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("porthole-thumbnail-\(UUID().uuidString).jpg")
        do { try data.write(to: file) } catch { return nil }
        return file
    }
}

struct TransferThumbnailView: View {
    let source: TransferSource
    let url: URL
    let name: String
    var side: CGFloat = 44
    @State private var image: UIImage?
    @State private var duration: TimeInterval?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let duration {
                            Text(Self.format(duration))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                .padding(3)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: side, height: side)
                    .overlay {
                        VStack(spacing: 2) {
                            Image(systemName: "doc")
                                .font(.system(size: 17, weight: .medium))
                            let ext = (name as NSString).pathExtension.uppercased()
                            if !ext.isEmpty {
                                Text(String(ext.prefix(4)))
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
            }
        }
        .accessibilityHidden(true)
        .task(id: name) {
            image = await TransferThumbnail.image(for: source, url: url, side: side)
            duration = TransferThumbnail.duration(for: source)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
