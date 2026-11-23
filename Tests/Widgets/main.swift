import Foundation

func require(_ condition: Bool, _ description: String) {
    guard condition else {
        FileHandle.standardError.write(Data((description + "\n").utf8))
        exit(1)
    }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
var state = WidgetInboxSnapshot()
require(state.summary(at: now) == .open, "Missing state must open Porthole")
state.pairing = .unpaired
require(state.summary(at: now) == .pair, "New installation must offer pairing")
state.pairing = .paired
require(state.summary(at: now) == .empty, "A paired iPhone can have no received files")
state.hasReceivedFiles = true
require(state.summary(at: now) == .caughtUp, "Viewed or cleared history must stay caught up")

state.transfer = .init(phase: .receiving, reportedAt: now)
require(state.summary(at: now) == .receiving, "A started transfer must remain distinct from a saved file")
require(state.summary(at: now.addingTimeInterval(600)) == .transferStatusUnknown, "A stale snapshot cannot establish a transfer failure")
require(state.transfer?.shouldRefresh(for: .receiving, at: now.addingTimeInterval(59)) == false, "Progress bursts must not repeatedly publish")
require(state.transfer?.shouldRefresh(for: .receiving, at: now.addingTimeInterval(60)) == true, "Continuing progress extends the active window")
require(state.transfer?.shouldRefresh(for: .saving, at: now) == true, "A phase change must publish immediately")
state.transfer?.reportedAt = now.addingTimeInterval(60)
require(state.summary(at: now.addingTimeInterval(600)) == .receiving, "A refreshed slow transfer still looks active")
state.transfer = .init(phase: .failed, reportedAt: now)
require(state.summary(at: now).destination == .transfer, "Save failures must open transfer status")
require(state.summary(at: now) == .transferNeedsAttention, "Only a reported failure needs attention")
state.unreadCount = 2
state.pairing = .disconnected
require(state.summary(at: now) == .unread(2), "Previously received files remain available offline")
require(state.summary(at: now).destination == .received, "Unread files must open Received")
require(WidgetInboxSummary.unread(1).title == "1 new file", "A single unread file uses the singular")

let hidden = state.summary(at: now, redacted: true)
require(hidden == .privateReceived, "System privacy must hide counts and transfer state")
require(hidden.destination == .received, "Hidden accessories use the neutral Received destination")
require(state.summary(at: now) == .unread(2), "Unredacted widgets retain the count")

for destination in WidgetDestination.allCases {
    require(WidgetDestination(url: destination.url) == destination, "Every widget route must round trip")
}
for input in [
    "porthole://open/send", "porthole-widget://other/send", "porthole-widget://open:80/send",
    "porthole-widget://open/%73end", "porthole-widget://someone@open/send",
    "porthole-widget://open/send?path=unreviewed", "porthole-widget://open/share#now",
    "porthole-widget://open//send", "porthole-widget://open/unknown"
] {
    require(WidgetDestination(url: URL(string: input)!) == nil, "Unexpected URLs must be ignored")
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-widget-tests-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let store = WidgetInboxStore(container: root)
require(store.load() == nil, "Fresh install should have no widget file")
try store.save(state)
require(store.load() == state, "A new widget instance must read the saved snapshot")
let snapshotData = try Data(contentsOf: root.appendingPathComponent("Widgets/Inbox.json"))
let keys = (try JSONSerialization.jsonObject(with: snapshotData)) as? [String: Any]
require(Set(keys?.keys.map { $0 } ?? []) == ["unreadCount", "hasReceivedFiles", "pairing", "transfer"],
        "Only the approved aggregate widget fields may be published")
state.unreadCount = 0
state.transfer = nil
try store.save(state)
require(store.load()?.summary(at: now) == .caughtUp, "Reading or clearing receipts must update the persisted widget")
try Data(repeating: 0, count: 4_097).write(to: root.appendingPathComponent("Widgets/Inbox.json"))
require(store.load() == nil, "An oversized snapshot should fall back to the default")

try store.save(state)
var reloads = 0
let publisher = WidgetInboxPublisher(store: store) { reloads += 1 }
publisher.update { _ in }
let waitUntil = Date().addingTimeInterval(2)
while reloads == 0 && Date() < waitUntil {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
require(reloads == 1, "A new app process must request a reload even if the restored snapshot is identical")
var legacy = keys ?? [:]
legacy["hideLockScreenDetails"] = true
let decoded = try JSONDecoder().decode(WidgetInboxSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
require(decoded.summary(at: now) == .unread(2), "A prior privacy preference must leave control to iOS")

print("Widget tests passed: receipts, stale transfers, privacy, routes, atomic snapshots and startup reload recovery.")
