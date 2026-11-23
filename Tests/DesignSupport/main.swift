import Foundation

func require(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-design-tests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let suite = "porthole.design.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

func write(_ name: String, _ value: String) throws -> URL {
    let file = root.appendingPathComponent(name)
    try Data(value.utf8).write(to: file)
    return file
}

func testCollisionAndFailures() throws {
    let folder = root.appendingPathComponent("received", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 1...70 {
        let name = index == 1 ? "report.pdf" : "report \(index).pdf"
        try Data("original-\(index)".utf8).write(to: folder.appendingPathComponent(name))
    }
    let source = try write("incoming.tmp", "new data")
    let result = try ReceivedFileWriter.save(source, named: "report.pdf", in: folder)
    require(result.lastPathComponent == "report 71.pdf", "collisions beyond 50 must not overwrite files")
    require(try String(contentsOf: folder.appendingPathComponent("report.pdf"), encoding: .utf8) == "original-1", "original file changed")
    require(try String(contentsOf: result, encoding: .utf8) == "new data", "saved payload differs")
    require(FileManager.default.fileExists(atPath: source.path), "writer must retain source until caller commits")
    for name in ["../escape.pdf", "/absolute.pdf", "..", ".hidden", "bad\\file.pdf", "bad:file.pdf", "bad\nfile.pdf"] {
        do { _ = try ReceivedFileWriter.save(source, named: name, in: folder); fatalError("accepted unsafe name: \(name)") }
        catch { require(FileManager.default.fileExists(atPath: source.path), "failed save removed source") }
    }
    let obstruction = try write("not-a-directory", "keep")
    do { _ = try ReceivedFileWriter.save(source, named: "safe.pdf", in: obstruction); fatalError("saved into a file") }
    catch { require(FileManager.default.fileExists(atPath: source.path), "destination failure removed source") }
}

func testStorageReferences() throws {
    let local = root.appendingPathComponent("Porthole", isDirectory: true)
    let previews = root.appendingPathComponent("previews", isDirectory: true)
    let storage = ReceivedFileStorage(defaultFolder: local, previewFolder: previews, defaults: defaults)
    require(!storage.usesCustomFolder, "custom folder should default off")
    let source = try write("received.tmp", "document")
    let saved = try storage.save(source, named: "original.pdf")
    require(saved.warning == nil, "default save should not warn")
    require(saved.reference.name == "original.pdf", "file name lost")
    require(!FileManager.default.fileExists(atPath: source.path), "committed temporary source not released")
    let opened = try storage.prepareForReading(saved.reference)
    require(try String(contentsOf: opened, encoding: .utf8) == "document", "saved file cannot reopen")
    storage.resetFolder()
    require(try storage.prepareForReading(saved.reference) == opened, "reset changed existing file location")
    storage.releasePreview(opened)
    require(FileManager.default.fileExists(atPath: opened.path), "releasePreview deleted a real document")
    let ownedPreviewDirectory = previews.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: ownedPreviewDirectory, withIntermediateDirectories: true)
    let ownedPreview = ownedPreviewDirectory.appendingPathComponent("preview.pdf")
    try Data("preview".utf8).write(to: ownedPreview)
    storage.releasePreview(ownedPreview)
    require(!FileManager.default.fileExists(atPath: ownedPreviewDirectory.path), "owned temporary preview was not released")
    let neighbouring = root.appendingPathComponent("previews-other", isDirectory: true)
    try FileManager.default.createDirectory(at: neighbouring, withIntermediateDirectories: true)
    let unrelated = neighbouring.appendingPathComponent("keep.pdf")
    try Data("keep".utf8).write(to: unrelated)
    storage.releasePreview(unrelated)
    require(FileManager.default.fileExists(atPath: unrelated.path), "preview cleanup escaped its directory")
    do { _ = try storage.prepareForReading(ReceivedFileReference(name: "../escape")); fatalError("unsafe reference opened") }
    catch { }
    let record = ActivityRecord(title: "original.pdf", detail: "Received", isFile: true, incoming: true,
                                receivedFile: saved.reference, isUnread: true)
    let restored = try JSONDecoder().decode(ActivityRecord.self, from: JSONEncoder().encode(record))
    require(restored.fileReference == saved.reference, "per-file reference not persisted")
    require(restored.isUnreadReceivedFile, "a new receipt must remain unread across relaunch")
    let clipboardRecord = ActivityRecord(title: "Clipboard", detail: "Received", isFile: false, incoming: true, isUnread: true)
    require(!clipboardRecord.isUnreadReceivedFile, "clipboard activity must not count as a received file")
    let bookmark = Data([1, 2, 3])
    defaults.set(try JSONSerialization.data(withJSONObject: ["bookmark": bookmark.base64EncodedString(), "name": "Unavailable folder"]),
                 forKey: "porthole.receivedSaveFolder")
    require(storage.usesCustomFolder, "saved folder selection not loaded")
    let another = try write("fallback.tmp", "fallback content")
    let fallback = try storage.save(another, named: "fallback.pdf")
    require(fallback.warning != nil && fallback.reference.folderBookmark == nil, "unavailable folder must visibly fall back to local storage")
    require(try storage.prepareForReading(fallback.reference).lastPathComponent == "fallback.pdf", "fallback cannot reopen")
    do {
        _ = try storage.prepareForReading(ReceivedFileReference(name: "original.pdf", folderName: "External", folderBookmark: bookmark))
        fatalError("an unavailable external file opened an unrelated same-name local file")
    } catch { }
    storage.resetFolder()
    require(try storage.prepareForReading(saved.reference) == opened, "changing folder broke an older file")
    try FileManager.default.moveItem(at: opened, to: local.appendingPathComponent("renamed.pdf"))
    try Data("replacement document".utf8).write(to: opened)
    do { _ = try storage.prepareForReading(saved.reference); fatalError("history opened a replacement at the old location") }
    catch { }
    let failed = try write("journal-failure.tmp", "retry data")
    do {
        _ = try storage.save(failed, named: "not-recorded.pdf", record: { _ in throw CocoaError(.fileWriteUnknown) })
        fatalError("reported save after receipt commit failed")
    } catch {
        require(FileManager.default.fileExists(atPath: failed.path), "receipt failure destroyed the source")
        require(!FileManager.default.fileExists(atPath: local.appendingPathComponent("not-recorded.pdf").path),
                "receipt failure left an untracked publication")
    }
}

func testLegacyAndClipboardHistory() throws {
    struct Legacy: Codable {
        var id = UUID()
        var date = Date()
        var title = "legacy.pdf"
        var detail = "Received from PC"
        var isFile = true
        var incoming = true
        var path: String? = "legacy.pdf"
    }
    defaults.set(try JSONEncoder().encode([Legacy()]), forKey: "porthole.activity")
    let store = ActivityHistoryStore(root: root.appendingPathComponent("history"), defaults: defaults)
    var records = try store.load()
    require(records.count == 1 && records[0].fileReference?.name == "legacy.pdf", "legacy history failed migration")
    require(!records[0].isUnreadReceivedFile, "upgrading old Activity must preserve its previously read appearance")
    require(records[0].clipboardText == nil, "legacy shortened text must not be treated as full clipboard")
    require(defaults.data(forKey: "porthole.activity") == nil, "legacy data retained after durable migration")
    let fullText = String(repeating: "Full text — 👋\n", count: 100)
    records.insert(ActivityRecord(title: "short preview…", detail: "Received", isFile: false, incoming: true, clipboardText: fullText), at: 0)
    let imageTemplate = ActivityRecord(title: "Image", detail: "Received", isFile: false, incoming: true)
    records = try store.saveClipboardImage(Data([137, 80, 78, 71]), record: imageTemplate, before: records)
    let image = records[0].clipboardImage!
    records = try store.load()
    require(records[1].clipboardText == fullText, "full multiline clipboard content was truncated")
    require(store.clipboardImageURL(image) != nil, "image history payload not retained")
    require(store.clipboardImageURL("../escape.png") == nil, "image cache accepted path traversal")
    let actualFile = try write("file-history-must-not-delete.pdf", "keep me")
    try store.clear()
    require(try store.load().isEmpty, "history did not clear")
    require(FileManager.default.fileExists(atPath: actualFile.path), "clearing history deleted a document")
    require(store.clipboardImageURL(image) == nil, "clearing history retained its owned clipboard cache")
    let expired = try store.saveClipboardImage(Data([1]), record: imageTemplate, before: [])[0].clipboardImage!
    var many = (0..<110).map { ActivityRecord(title: "item \($0)", detail: "Sent", isFile: false, incoming: false) }
    many[109].clipboardImage = expired
    many.append(ActivityRecord(title: "Older file", detail: "Received", isFile: true, incoming: true))
    try store.save(many)
    require(try store.load().count == 101, "clipboard history exceeded its limit")
    require(try store.load().last?.title == "Older file", "clipboard eviction removed file history")
    require(store.clipboardImageURL(expired) == nil, "evicted clipboard payload not cleaned up")
    let oldImage = try store.saveClipboardImage(Data([2]), record: imageTemplate, before: [])[0].clipboardImage!
    let eightDaysAgo = Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)
    try store.save([
        ActivityRecord(date: eightDaysAgo, title: "Old clipboard", detail: "Received", isFile: false, incoming: true, clipboardImage: oldImage),
        ActivityRecord(date: eightDaysAgo, title: "Old file", detail: "Received", isFile: true, incoming: true)
    ])
    require(try store.load().map(\.title) == ["Old file"], "age retention removed a file or kept expired clipboard history")
    require(store.clipboardImageURL(oldImage) == nil, "expired clipboard image was left on disk")
    let fullImage = Data(repeating: 1, count: 8 * 1024 * 1024)
    let first = try store.saveClipboardImage(fullImage, record: imageTemplate, before: try store.load())
    let second = try store.saveClipboardImage(fullImage, record: imageTemplate, before: first)
    let firstImage = first[0].clipboardImage!
    let secondImage = second[0].clipboardImage!
    let third = try store.saveClipboardImage(Data([1]), record: imageTemplate, before: second)
    require(third.count == 3, "new clipboard image evicted a file or did not replace the oldest image")
    require(store.clipboardImageURL(firstImage) == nil && store.clipboardImageURL(secondImage) != nil,
            "only the oldest image should be evicted to stay under budget")
    require(third[0].clipboardImage.flatMap(store.clipboardImageURL) != nil,
            "newest clipboard image should be retained")

    let incoming = ActivityRecord(title: "Incoming file", detail: "Received", isFile: true, incoming: true, isUnread: true)
    let imported = try store.importReceived(incoming, into: third)
    require(imported.filter { $0.id == incoming.id }.count == 1, "A durable import adds one Activity item")
    try store.clear()
    let restarted = ActivityHistoryStore(root: root.appendingPathComponent("history"), defaults: defaults)
    let cleared = try restarted.load()
    require(try restarted.importReceived(incoming, into: cleared).isEmpty,
            "A pending marker must never resurrect a deliberately cleared receipt")
    restarted.completeIncomingImport(incoming.id)
}

func testProtocolNames() {
    require(TransferFileName.make("Q3 report.pdf", index: 0) == "Q3_report.pdf", "spaces must not break the wire protocol")
    for input in ["../../../outside.pdf", ".", "", "hello\nPUSH 9 injected", "Ünicode.heic", String(repeating: "a", count: 300) + ".pdf"] {
        let name = TransferFileName.make(input, index: 0)
        require(name.count <= 78 && name.contains(".") && !name.hasPrefix(".") && !name.contains("/") && !name.contains(" ") && !name.contains("\n"), "unsafe wire file name")
    }
    require(TransferFileName.make("IMG_1234.HEIC", index: 0) == "IMG_1234.HEIC", "valid original name and format changed")
    require(TransferFileName.make("NUL.log", index: 0).lowercased() != "nul.log", "Windows reserved destination was kept")
}

func testTransferStaging() throws {
    let bytes = Data(repeating: 42, count: (1 << 20) + 1)
    let source = root.appendingPathComponent("staging-source.bin")
    let destination = root.appendingPathComponent("staged.bin")
    try bytes.write(to: source)
    var checks = 0
    do {
        _ = try TransferStaging.copy(source, to: destination, remaining: Int64(bytes.count)) {
            checks += 1
            return checks > 2
        }
        fatalError("cancelled staging completed")
    } catch TransferStaging.Failure.cancelled {
        require(!FileManager.default.fileExists(atPath: destination.path), "cancelled staging left a partial copy")
    }
    do {
        _ = try TransferStaging.copy(source, to: destination, remaining: 1) { false }
        fatalError("staging exceeded the remaining batch budget")
    } catch TransferStaging.Failure.batchLimit { }
    let size = try TransferStaging.copy(source, to: destination, remaining: Int64(bytes.count)) { false }
    let restored = try Data(contentsOf: destination)
    require(size == bytes.count && restored == bytes, "staging changed the bytes")
    let link = root.appendingPathComponent("staging-link.bin")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    do {
        _ = try TransferStaging.copy(link, to: root.appendingPathComponent("staged-link.bin"), remaining: size) { false }
        fatalError("staging followed a symbolic link")
    } catch TransferStaging.Failure.invalidFile { }
    let oversized = root.appendingPathComponent("oversized.bin")
    try Data([0]).write(to: oversized)
    let writer = try FileHandle(forWritingTo: oversized)
    try writer.truncate(atOffset: UInt64(TransferStaging.desktopFileBytes) + 1)
    try writer.close()
    do {
        _ = try TransferStaging.copy(oversized, to: root.appendingPathComponent("oversized-copy.bin"),
                                     remaining: TransferStaging.maxBatchBytes, forDesktop: true) { false }
        fatalError("PC upload checked the file size after staging")
    } catch TransferStaging.Failure.desktopFileLimit { }
}

func testShareReceipts() throws {
    let journal = ShareReceiptJournal(containerURL: root)
    let first = ShareReceipt(id: UUID(), date: Date(timeIntervalSince1970: 10), peerName: "Work PC", name: "photo.jpg", bytes: 10)
    let second = ShareReceipt(id: UUID(), date: Date(timeIntervalSince1970: 20), peerName: "Work PC", name: "note.txt", bytes: 4)
    try journal.record(second)
    try journal.record(first)
    try journal.record(first)
    require(try journal.pending() == [first, second], "duplicate or unordered pending Share receipts")
    try journal.remove(first.id)
    try journal.remove(first.id)
    require(try journal.pending() == [second], "receipt consumption removed another transfer")
}

func testDefaultFolderUpgrade() throws {
    let documents = root.appendingPathComponent("Documents", isDirectory: true)
    let oldFolder = documents.appendingPathComponent("Porthole", isDirectory: true)
    let storage = ReceivedFileStorage(defaultFolder: documents, legacyDefaultFolder: oldFolder,
                                      previewFolder: root.appendingPathComponent("migration-previews"), defaults: defaults)
    try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
    let oldFile = oldFolder.appendingPathComponent("Invoice.pdf")
    try Data("old document".utf8).write(to: oldFile)
    let legacy = ReceivedFileReference(name: oldFile.lastPathComponent)
    let saved = try storage.save(write("migration.tmp", "new document"), named: legacy.name)
    require(saved.localURL == documents.appendingPathComponent(legacy.name), "New files must save in the visible Porthole root")
    require(try storage.prepareForReading(saved.reference) == saved.localURL, "New history must open the root file")
    require(try storage.prepareForReading(legacy) == oldFile, "Old history must still open the same nested file")
}

try testCollisionAndFailures()
try testStorageReferences()
try testDefaultFolderUpgrade()
try testLegacyAndClipboardHistory()
testProtocolNames()
try testTransferStaging()
try testShareReceipts()
print("Design support tests passed: history retention, file identity and rollback, bounded staging, protocol names and Share receipts.")
