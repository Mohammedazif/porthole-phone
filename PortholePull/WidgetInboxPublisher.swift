import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The app is the only writer. WidgetKit reads an atomic, privacy-filtered snapshot.
final class WidgetInboxPublisher {
    private let store: WidgetInboxStore?
    private let requestReload: () -> Void
    private let queue = DispatchQueue(label: "porthole.widget-inbox", qos: .utility)
    /// Shared with app UI on the main queue only.
    private(set) var snapshot: WidgetInboxSnapshot
    /// Only accessed on queue after initialization.
    private var persisted: WidgetInboxSnapshot?
    private var requestedInitialReload = false

    init(store: WidgetInboxStore? = WidgetInboxStore.shared(), requestReload: @escaping () -> Void = {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetInboxSnapshot.kind)
        #endif
    }) {
        self.store = store
        self.requestReload = requestReload
        let restored = store?.load()
        snapshot = restored ?? WidgetInboxSnapshot()
        persisted = restored
        if snapshot.transfer?.phase.inProgress == true {
            snapshot.transfer = .init(phase: .interrupted, reportedAt: Date())
        }
    }

    func update(_ change: (inout WidgetInboxSnapshot) -> Void) {
        change(&snapshot)
        guard let store else { return }
        let proposed = snapshot
        queue.async { self.persist(proposed, to: store) }
    }

    private func persist(_ proposed: WidgetInboxSnapshot, to store: WidgetInboxStore) {
        do {
            let changed = persisted != proposed
            if changed {
                try store.save(proposed)
                persisted = proposed
            }
            // A previous app process may have saved successfully but exited before reloading.
            guard changed || !requestedInitialReload else { return }
            requestedInitialReload = true
            DispatchQueue.main.async(execute: requestReload)
        } catch {
            // Preserve the previous atomic snapshot and retry at the next app event.
        }
    }
}
