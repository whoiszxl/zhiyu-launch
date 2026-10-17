import Foundation

/// One cell in the persisted layout: either a loose app or a folder.
enum LayoutItem: Codable, Sendable, Hashable {
    case app(String)
    case folder(LayoutFolder)

    /// All bundle identifiers contained in this item.
    var appIDs: [String] {
        switch self {
        case .app(let id): return [id]
        case .folder(let folder): return folder.appIDs
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case kind, appID, folder }
    private enum Kind: String, Codable { case app, folder }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .app: self = .app(try container.decode(String.self, forKey: .appID))
        case .folder: self = .folder(try container.decode(LayoutFolder.self, forKey: .folder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let id):
            try container.encode(Kind.app, forKey: .kind)
            try container.encode(id, forKey: .appID)
        case .folder(let folder):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(folder, forKey: .folder)
        }
    }
}

/// A user-created folder of apps.
struct LayoutFolder: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var appIDs: [String]

    static var defaultName: String {
        L10n.t("文件夹", "Folder")
    }

    init(id: UUID = UUID(), name: String, appIDs: [String]) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
    }
}

/// On-disk representation of the user layout.
struct LayoutFile: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var items: [LayoutItem]
}

/// Stable reference to a layout item, used by drag & drop moves.
enum LayoutItemRef: Sendable, Hashable {
    case app(String)
    case folder(UUID)
}

/// Mutable view of the persisted layout.
///
/// The layout stores a **flat** ordered list of items; pages are derived from the
/// current screen metrics at display time. This keeps the persisted data stable
/// across displays with different grid sizes.
struct LayoutModel: Sendable, Equatable {
    private(set) var items: [LayoutItem]

    init(items: [LayoutItem] = []) {
        self.items = items
    }

    init(file: LayoutFile) {
        self.items = file.items
    }

    var file: LayoutFile {
        LayoutFile(version: LayoutFile.currentVersion, items: items)
    }

    var appIDs: [String] { items.flatMap(\.appIDs) }

    func contains(appID: String) -> Bool {
        items.contains { $0.appIDs.contains(appID) }
    }

    func contains(ref: LayoutItemRef) -> Bool {
        switch ref {
        case .app(let id): return contains(appID: id)
        case .folder(let id): return folder(id: id) != nil
        }
    }

    func folder(id: UUID) -> LayoutFolder? {
        for item in items {
            if case .folder(let folder) = item, folder.id == id { return folder }
        }
        return nil
    }

    /// Index of the grid position that ultimately contains `appID`
    /// (the folder's index when the app lives inside a folder).
    func gridIndex(containing appID: String) -> Int? {
        items.firstIndex { $0.appIDs.contains(appID) }
    }

    func index(of ref: LayoutItemRef) -> Int? {
        switch ref {
        case .app(let id): return gridIndex(containing: id)
        case .folder(let id): return items.firstIndex { if case .folder(let f) = $0 { return f.id == id } else { return false } }
        }
    }

    func ref(ofItemAt index: Int) -> LayoutItemRef? {
        guard items.indices.contains(index) else { return nil }
        switch items[index] {
        case .app(let id): return .app(id)
        case .folder(let folder): return .folder(folder.id)
        }
    }

    // MARK: - Reconciliation

    /// Reconciles the layout with a freshly scanned catalog.
    ///
    /// - Removes apps that no longer exist.
    /// - Dissolves folders that dropped below two members (the remaining app returns to the grid).
    /// - Appends newly installed apps (in catalog order, which is name-sorted).
    ///
    /// Returns `true` when the layout actually changed.
    @discardableResult
    mutating func reconcile(with catalog: [AppItem]) -> Bool {
        let known = Set(catalog.map(\.bundleID))
        let before = items
        var result: [LayoutItem] = []
        var placed = Set<String>()

        for item in items {
            switch item {
            case .app(let id):
                if known.contains(id), !placed.contains(id) {
                    placed.insert(id)
                    result.append(.app(id))
                }
            case .folder(var folder):
                folder.appIDs = folder.appIDs.filter { known.contains($0) && !placed.contains($0) }
                folder.appIDs.forEach { placed.insert($0) }
                if folder.appIDs.count >= 2 {
                    result.append(.folder(folder))
                } else {
                    // Dissolve: zero members disappear, one member returns to the grid.
                    for id in folder.appIDs { result.append(.app(id)) }
                }
            }
        }

        for app in catalog where !placed.contains(app.bundleID) {
            result.append(.app(app.bundleID))
        }

        items = result
        return items != before
    }

    // MARK: - Mutations

    /// Moves an existing item so it is placed directly before `target`
    /// (or at the end when `target` is nil or no longer present).
    @discardableResult
    mutating func move(_ ref: LayoutItemRef, before target: LayoutItemRef?) -> Bool {
        guard contains(ref: ref) else { return false }
        if let target, target == ref { return false }

        guard let value = removeItem(ref) else { return false }

        if let target, let targetIndex = index(of: target) {
            items.insert(value, at: targetIndex)
        } else {
            items.append(value)
        }
        return true
    }

    /// Creates a folder from `appID` dropped onto `targetAppID`, replacing the
    /// target app's grid position with the new folder.
    @discardableResult
    mutating func createFolder(with appID: String, onto targetAppID: String, name: String = LayoutFolder.defaultName) -> UUID? {
        guard appID != targetAppID,
              contains(appID: appID),
              contains(appID: targetAppID) else { return nil }

        // Moving an app out of a folder onto a loose app folds both into one folder.
        removeCompletely(appID: appID)
        guard let targetIndex = gridIndex(containing: targetAppID) else { return nil }

        let folder = LayoutFolder(name: name, appIDs: [targetAppID, appID])
        items[targetIndex] = .folder(folder)
        return folder.id
    }

    /// Adds an app to an existing folder (dropped directly onto the folder).
    @discardableResult
    mutating func add(appID: String, toFolder folderID: UUID) -> Bool {
        guard let folder = folder(id: folderID), !folder.appIDs.contains(appID) else { return false }

        // The app may currently live inside another folder; removal can dissolve that folder.
        removeCompletely(appID: appID)

        guard let index = index(of: .folder(folderID)), case .folder(var updated) = items[index] else { return false }
        updated.appIDs.append(appID)
        items[index] = .folder(updated)
        return true
    }

    /// Removes an app from a folder; dissolves the folder when fewer than two apps remain.
    @discardableResult
    mutating func remove(appID: String, fromFolder folderID: UUID) -> Bool {
        guard let index = index(of: .folder(folderID)), case .folder(var folder) = items[index],
              let position = folder.appIDs.firstIndex(of: appID) else { return false }

        folder.appIDs.remove(at: position)

        if folder.appIDs.count >= 2 {
            items[index] = .folder(folder)
        } else {
            // Dissolve: keep remaining members on the grid, then append the removed app after them.
            items.remove(at: index)
            var insertAt = index
            for id in folder.appIDs {
                items.insert(.app(id), at: insertAt)
                insertAt += 1
            }
            items.insert(.app(appID), at: min(insertAt, items.count))
        }
        return true
    }

    /// Breaks a folder apart, returning all members to the grid.
    @discardableResult
    mutating func dissolve(folderID: UUID) -> Bool {
        guard let index = index(of: .folder(folderID)), case .folder(let folder) = items[index] else { return false }
        items.remove(at: index)
        for (offset, id) in folder.appIDs.enumerated() {
            items.insert(.app(id), at: index + offset)
        }
        return true
    }

    @discardableResult
    mutating func rename(folderID: UUID, to name: String) -> Bool {
        guard let index = index(of: .folder(folderID)), case .folder(var folder) = items[index] else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? LayoutFolder.defaultName : trimmed
        guard case .folder(let old) = items[index], old.name != folder.name else { return false }
        items[index] = .folder(folder)
        return true
    }

    /// Moves an app inside a folder so it sits directly before `targetAppID`.
    @discardableResult
    mutating func moveInFolder(folderID: UUID, appID: String, before targetAppID: String) -> Bool {
        guard appID != targetAppID,
              let index = index(of: .folder(folderID)),
              case .folder(var folder) = items[index],
              let from = folder.appIDs.firstIndex(of: appID),
              let to = folder.appIDs.firstIndex(of: targetAppID) else { return false }

        folder.appIDs.remove(at: from)
        let insertAt = from < to ? to - 1 : to
        folder.appIDs.insert(appID, at: insertAt)
        items[index] = .folder(folder)
        return true
    }

    // MARK: - Private helpers

    /// Removes the given ref from the layout and returns the removed value.
    /// Apps removed from folders dissolve the folder when only one member remained;
    /// the removed app is returned to the caller and is *not* re-inserted here.
    private mutating func removeItem(_ ref: LayoutItemRef) -> LayoutItem? {
        switch ref {
        case .app(let id):
            guard contains(appID: id) else { return nil }
            removeCompletely(appID: id)
            return .app(id)
        case .folder(let id):
            if let index = index(of: .folder(id)) {
                return items.remove(at: index)
            }
            return nil
        }
    }

    /// Removes an app from wherever it lives, dissolving any folder that drops
    /// below two members (remaining members return to the grid).
    private mutating func removeCompletely(appID: String) {
        if let index = gridIndex(containing: appID), case .app = items[index] {
            items.remove(at: index)
            return
        }
        for index in items.indices {
            guard case .folder(var folder) = items[index],
                  let position = folder.appIDs.firstIndex(of: appID) else { continue }
            folder.appIDs.remove(at: position)
            if folder.appIDs.count >= 2 {
                items[index] = .folder(folder)
            } else {
                items.remove(at: index)
                for (offset, member) in folder.appIDs.enumerated() {
                    items.insert(.app(member), at: index + offset)
                }
            }
            return
        }
    }
}
