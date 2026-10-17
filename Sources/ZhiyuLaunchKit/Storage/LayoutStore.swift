import Foundation

/// Reads/writes the layout JSON in `~/Library/Application Support/ZhiyuLaunch/layout.json`.
struct LayoutStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            let dir = base.appendingPathComponent("ZhiyuLaunch", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("layout.json")
        }
    }

    func load() -> LayoutModel {
        guard let data = try? Data(contentsOf: fileURL) else { return LayoutModel() }
        do {
            return LayoutModel(file: try JSONDecoder().decode(LayoutFile.self, from: data))
        } catch {
            // Keep the unreadable file around for debugging instead of silently overwriting it.
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return LayoutModel()
        }
    }

    func save(_ model: LayoutModel) {
        guard let data = try? JSONEncoder().encode(model.file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Owns the in-memory layout, reconciles it with catalog updates and debounces disk writes.
@MainActor
final class LayoutState {
    private(set) var model: LayoutModel
    private let store: LayoutStore
    private var pendingSave: DispatchWorkItem?

    init(store: LayoutStore = LayoutStore()) {
        self.store = store
        self.model = store.load()
    }

    /// Applies a mutation. Saves to disk (debounced) only when the model changed.
    @discardableResult
    func mutate(_ body: (inout LayoutModel) -> Bool) -> Bool {
        let changed = body(&model)
        if changed { scheduleSave() }
        return changed
    }

    func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        store.save(model)
    }
}
