import Foundation
import Observation

/// Fine-grained observation keeps scan counters out of AppModel.objectWillChange.
@Observable @MainActor final class PreparationPresentationState {
    private(set) var progress = LibraryPreparationProgress()
    var discovery = ScanDiscovery(revision: 0, places: [])
    var recentPlace: TravelPlace?
    @ObservationIgnored private var pending: LibraryPreparationProgress?
    @ObservationIgnored private var publication: Task<Void, Never>?

    func update(_ value: LibraryPreparationProgress) {
        guard value != progress else { pending = nil; return }
        if value.phase != progress.phase || value.mode != progress.mode {
            publication?.cancel(); publication = nil; pending = nil
            progress = value
        } else {
            pending = value
            guard publication == nil else { return }
            publication = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if let pending = self.pending { self.progress = pending }
                self.pending = nil; self.publication = nil
            }
        }
    }
}
