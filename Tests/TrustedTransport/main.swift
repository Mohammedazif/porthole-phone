import Foundation

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

let pin = String(repeating: "a1", count: 32)
require(TrustedPeer.computerName("  Studio-PC ") == "Studio-PC", "Use the computer name")
require(TrustedPeer.computerName("Porthole") == "Porthole", "Accept Porthole as a computer name")
require(TrustedPeer.computerName("Porthole PC") == nil, "Ignore the generic desktop fallback")
require(TrustedPeer.computerName("192.0.2.42") == nil && TrustedPeer.computerName("2001:db8::42") == nil,
        "IP addresses are endpoints, not computer names")
require(TrustedPeer.computerName("Your PC") == nil && TrustedPeer.computerName("UNKNOWN") == nil,
        "Ignore computer-name placeholders")
let standardGroup = "group.local.porthole.pull"
let profileGroup = standardGroup + ".A1B2C3D4E5"
let xml = try PropertyListSerialization.data(
    fromPropertyList: ["Entitlements": ["com.apple.security.application-groups": [profileGroup]]],
    format: .xml, options: 0)
require(PortholeAppGroup.appGroups(inProvisioningProfile: Data([0x30, 0x80]) + xml + Data([0, 0])) == [profileGroup],
        "Read the provisioned app group from an embedded signing profile")
require(PortholeAppGroup.appGroups(inProvisioningProfile: Data([0, 1, 2])).isEmpty,
        "Ignore a missing or unsupported signing profile")
let alternatives = SavedPCLAN.alternateAddresses(for: "192.168.0.50", localAddresses: ["192.168.0.49"])
require(Array(alternatives.prefix(3)) == ["192.168.0.51", "192.168.0.48", "192.168.0.52"],
        "Try the saved PC's closest alternate addresses, excluding the phone")
require(SavedPCLAN.alternateAddresses(for: "192.168.0.50", localAddresses: ["192.168.1.49"]).isEmpty,
        "Only recover an address in the saved network range")
require(SavedPCLAN.alternateAddresses(for: "desk.local", localAddresses: ["192.168.0.51"]).isEmpty,
        "Do not scan a subnet when the saved hostname uses DNS")
let installerApp = "local.porthole.pull.A1B2C3D4E5"
for bundleID in [installerApp, installerApp + ".broadcast", installerApp + ".share", installerApp + ".widgets"] {
    require(PortholeAppGroup.installerGroup(for: bundleID, configuredGroup: standardGroup) == "group." + installerApp,
            "iLoader's app and companion extensions use the same provisioned group")
}
for bundleID in ["local.porthole.pull", installerApp + ".unrelated", "local.porthole.pull.custom",
                 "local.other.app.A1B2C3D4E5"] {
    require(PortholeAppGroup.installerGroup(for: bundleID, configuredGroup: standardGroup) == nil,
            "Only the expected team-suffixed companion bundles use the installer group")
}
let spaced = Array(repeating: "A1", count: 32).joined(separator: ":")
require(TrustedPeer.normalizeFingerprint(spaced) == pin, "Normalize an explicitly displayed certificate fingerprint")
require(TrustedPeer.normalizeFingerprint(String(pin.dropLast())) == nil, "Reject an incomplete fingerprint")
require(TrustedPeer.normalizeFingerprint(String(repeating: "j", count: 64)) == nil, "Reject a non-hex fingerprint")
require(TrustedPeer.isChannelTicket(pin), "Accept only the canonical channel ticket shape")
require(!TrustedPeer.isChannelTicket(spaced), "Reject display-formatted tickets")

require(TrustedPeer.pairingHost("192.168.0.50:47731") == "192.168.0.50", "Accept the address copied on the PC")
require(TrustedPeer.pairingHost("host.local:47732") == nil, "Reject the wrong companion port")
require(TrustedPeer.pairingHost("[::1]:47731") == "::1", "Accept bracketed IPv6 endpoints")
require(TrustedPeer.pairingHost("192.168.0.50:") == nil, "Rejected malformed endpoint")
let firstPeer = TrustedPeer(host: "192.168.0.50", name: "PC", fingerprint: pin, id: UUID())
let newSession = firstPeer.newSession(host: "192.168.0.51")
require(newSession.id != firstPeer.id && newSession.samePairing(as: firstPeer), "Change transport identity while retaining the same approved pairing")
require(newSession.credentialProfile == firstPeer.credentialProfile, "Preserve the credential profile after an address change")
let replacement = TrustedPeer(host: firstPeer.host, name: "PC", fingerprint: pin, id: UUID())
let authorization = PairedChannelAuthorization(peer: firstPeer, ticket: pin)!
require(authorization.connectionPeer(for: newSession.remembered)?.channelTicket == pin,
        "Extensions can connect after the foreground ticket has been discarded")
require(authorization.connectionPeer(for: replacement) == nil,
        "A Share credential cannot be reused for a replacement pairing")
require(PairedChannelAuthorization(peer: firstPeer, ticket: "malformed") == nil,
        "Reject an invalid Share credential")
require(!replacement.samePairing(as: firstPeer), "Explicit pairing has a new authorization identity")
require(replacement.credentialProfile != firstPeer.credentialProfile, "Explicit pairing cannot reuse the previous credential")
require(IncomingTransfer.chunkLength("CHUNK 65536", remaining: 65536) == 65536, "Accept a full interleaved chunk")
require(IncomingTransfer.chunkLength("CHUNK 65537", remaining: 65537) == nil, "Reject oversized chunks")
require(IncomingTransfer.chunkLength("CHUNK 1", remaining: 0) == nil, "Reject chunks beyond declared size")
let fileID = String(repeating: "b", count: 32)
let header = "PUSH2 \(fileID) \(pin) 10 Original name.pdf"
let transfer = IncomingTransfer(header: header)!
require(transfer.name == "Original name.pdf", "Preserve a valid filename containing spaces")
require(IncomingTransfer(header: "PUSH2 \(fileID) \(pin) 1 ../private.pdf") == nil, "Reject directory syntax")
require(IncomingTransfer(header: "PUSH2 \(fileID) \(pin) 536870913 large.pdf") == nil, "Reject a file above the declared limit")

let root = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-tests-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let store = IncomingTransferStore(root: root)

guard case .staged(let started) = try store.prepare(transfer, profile: pin) else { fatalError("New transfer must stage") }
require(started.offset == 0, "New transfer starts empty")
try started.handle.write(contentsOf: Data("12345".utf8))
try started.handle.close()
guard case .staged(let resumed) = try store.prepare(transfer, profile: pin) else { fatalError("Incomplete transfer must resume") }
require(resumed.offset == 5, "Interrupted body resumes from written bytes")
try resumed.handle.close()

let changed = IncomingTransfer(header: "PUSH2 \(fileID) \(pin) 11 Original name.pdf")!
do {
    _ = try store.prepare(changed, profile: pin)
    require(false, "An existing ID cannot change its manifest")
} catch { }

let receipt = try store.record(ReceivedFileReference(name: transfer.name, bytes: 10),
                               from: "Test PC", at: resumed.receipt)
require(store.unimportedReceipts().map { $0.1.reference.id } == [receipt.reference.id],
        "A committed file with pending Activity write has a stable import identity")
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)],
                                      ofItemAtPath: resumed.receipt.path)
store.reclaimExpired()
if case .saved(let pending, let path) = try store.prepare(transfer, profile: pin) {
    require(pending?.reference.id == receipt.reference.id && path == resumed.receipt,
            "An old saved receipt still needs Activity import when replayed")
} else { fatalError("Expiration discarded an unimported receipt") }
try store.markImported(resumed.receipt)
require(store.unimportedReceipts().isEmpty, "An imported record stays absent after clearing Activity")
if case .saved(let pending, _) = try store.prepare(transfer, profile: pin) {
    require(pending == nil, "Replaying a completed transfer must not resurrect history")
}
else { require(false, "A saved transfer must return the same durable result") }
let otherPin = String(repeating: "c", count: 64)
guard case .staged(let elsewhere) = try store.prepare(transfer, profile: otherPin) else { fatalError("Another PC must get a separate transfer") }
require(elsewhere.offset == 0, "Transfer IDs are scoped to the pinned PC")
try elsewhere.handle.close()

let folder = root.appendingPathComponent("saved", isDirectory: true)
let storage = ReceivedFileStorage(defaultFolder: folder, previewFolder: root.appendingPathComponent("previews"))
let source = root.appendingPathComponent("interrupted-body")
try Data("published".utf8).write(to: source)
var intent: ReceivedFileStorage.PublicationIntent?
let completed = try storage.save(source, named: "Document.txt", planStage: { staging in
    require(!FileManager.default.fileExists(atPath: ReceivedFileWriter.stagingFolder(staging.id, in: folder).path),
            "The intent must be durable before creating the staging directory")
    try store.planStaging(staging)
}, clearStage: store.completeStaging, plan: { intent = $0 })
require(store.pendingStaging().isEmpty, "Success removes the staging journal")
let recovered = storage.recover(intent!)!
require(recovered.reference.id == completed.reference.id, "A committed rename can be reconciled after loss of the receipt")
require(recovered.localURL == completed.localURL, "Reconciliation returns the same file")
let detached = folder.appendingPathComponent("Moved.txt")
try FileManager.default.moveItem(at: recovered.localURL!, to: detached)
try Data("different".utf8).write(to: recovered.localURL!)
require(storage.recover(intent!) == nil, "Do not import a replacement with the same name")

let interruptedID = UUID()
let interruptedOwner = UUID()
let interruptedFolder = ReceivedFileWriter.stagingFolder(interruptedID, in: folder)
try store.planStaging(.init(id: interruptedID, bookmark: nil, token: interruptedOwner))
try FileManager.default.createDirectory(at: interruptedFolder, withIntermediateDirectories: false)
try Data().write(to: ReceivedFileWriter.stagingMarker(interruptedOwner, in: interruptedFolder))
try Data("partial copy".utf8).write(to: interruptedFolder.appendingPathComponent("body"))
let snapshot = store.pendingStaging().first { $0.id == interruptedID }!
try storage.recoverStaging(snapshot)
store.completeStaging(interruptedID)
require(!FileManager.default.fileExists(atPath: interruptedFolder.path) && store.pendingStaging().isEmpty,
        "Restart removes the owned interrupted copy and its journal")
try FileManager.default.createDirectory(at: interruptedFolder, withIntermediateDirectories: false)
let replacementBody = interruptedFolder.appendingPathComponent("body")
try Data("keep".utf8).write(to: replacementBody)
try storage.recoverStaging(snapshot)
require(FileManager.default.fileExists(atPath: replacementBody.path), "Staging cleanup must not remove a replacement")

let outbound = OutboundTransferJournal(container: root)
var lease: OutboundTransferJournal.Batch? = try outbound.makeBatch(for: firstPeer)
try lease!.reserve(10)
let outgoingID = UUID()
let batch = OutboundTransferManifest(id: lease!.id, destination: firstPeer.remembered,
                                    files: [.init(id: outgoingID, name: "Report.pdf", bytes: 10, digest: pin, sent: false)],
                                    version: 3)
try lease!.save(batch)
require(outbound.openPending(for: firstPeer) == nil, "The Share and main app cannot claim the same pending batch")
lease = nil
require(outbound.openPending(for: replacement) == nil, "A new pairing must not inherit an approved old batch")
let (opened, stagedBatch) = outbound.openPending(for: newSession)!
require(stagedBatch.files.first?.id == outgoingID && stagedBatch.version == 3,
        "Reopened retries retain item IDs and negotiated integrity version")
require(stagedBatch.destination.channelTicket == nil, "A durable queue never stores a session ticket")
try opened.discard()

var old: OutboundTransferJournal.Batch? = try outbound.makeBatch(for: firstPeer)
try old!.reserve(10)
try old!.save(OutboundTransferManifest(id: old!.id, destination: firstPeer.remembered, files: batch.files))
let oldFolder = old!.folder
old = nil
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)],
                                      ofItemAtPath: oldFolder.appendingPathComponent("batch.json").path)
require(outbound.openPending(for: firstPeer) == nil, "Expired batches cannot be reopened")
outbound.reclaimExpired()
require(!FileManager.default.fileExists(atPath: oldFolder.path), "Launch cleanup removes expired pending batches")

var interruptedSend: OutboundTransferJournal.Batch? = try outbound.makeBatch(for: firstPeer)
let providerItem = OutboundTransferManifest.File(id: UUID(), name: "File-20261123-090011-1.jpg", bytes: 10,
                                                 digest: pin, sent: false, generatedName: true)
try interruptedSend!.reserve(10)
try interruptedSend!.save(.init(id: interruptedSend!.id, destination: firstPeer.remembered,
                                files: [providerItem], version: 3))
interruptedSend = nil
let renewed = try outbound.makeBatch(for: newSession)
try renewed.reserve(10)
let newName = "File-20261123-090123-2.jpg"
let newItem = renewed.itemURL(named: newName, index: 0)
try FileManager.default.createDirectory(at: newItem.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data(repeating: 42, count: 10).write(to: newItem)
let selected = try renewed.saveSelection(.init(id: renewed.id, destination: newSession.remembered,
                                               files: [.init(id: UUID(), name: newName, bytes: 10,
                                                             digest: pin, sent: false, generatedName: true)]), version: 3)
require(selected.files[0].id == providerItem.id && selected.files[0].name == providerItem.name,
        "Re-selecting a provider file must resume the original file identity and wire name")
require(FileManager.default.fileExists(atPath: renewed.itemURL(named: providerItem.name, index: 0).path),
        "A re-selected snapshot must be available under its original wire name")
let shareReceipts = ShareReceiptJournal(containerURL: root)
try shareReceipts.record(.init(id: providerItem.id, date: Date(), peerName: firstPeer.name,
                               name: providerItem.name, bytes: 10, pairingID: firstPeer.stableID))
try shareReceipts.markImported(providerItem.id)
require(outbound.openPending(for: firstPeer) == nil, "An imported receipt must clear the earlier pending item")
try renewed.discard()
outbound.reclaimExpired()

var active: OutboundTransferJournal.Batch? = try outbound.makeBatch(for: firstPeer)
let activeFolder = active!.folder
try active!.reserve(TransferStaging.maxFileBytes)
try active!.reserve(TransferStaging.maxFileBytes)
let otherBatch = try outbound.makeBatch(for: replacement)
do {
    try otherBatch.reserve(1)
    require(false, "The staging quota must be shared across both active batches")
} catch TransferStaging.Failure.sharedBudget { }
outbound.discard(for: firstPeer)
require(active!.isRevoked && !otherBatch.isRevoked, "Forget marks only batches from the old pairing, even while leased")
active = nil
require(!FileManager.default.fileExists(atPath: activeFolder.path), "Releasing a revoked lease removes its staged files")
try otherBatch.reserve(1)
try otherBatch.discard()

print("Trusted transport and incoming receipt tests passed")
