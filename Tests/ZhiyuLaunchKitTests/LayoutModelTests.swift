import Foundation
import Testing
@testable import ZhiyuLaunchKit

struct LayoutModelTests {
    private func app(_ id: String) -> AppItem {
        AppItem(bundleID: id, name: id, url: URL(fileURLWithPath: "/Applications/\(id).app"))
    }

    // MARK: - Reconcile

    @Test func reconcileAppendsNewAppsInCatalogOrder() {
        var model = LayoutModel(items: [.app("a"), .app("b")])
        let changed = model.reconcile(with: [app("a"), app("b"), app("c")])
        #expect(changed)
        #expect(model.items == [.app("a"), .app("b"), .app("c")])
        let changedAgain = model.reconcile(with: [app("a"), app("b"), app("c")])
        #expect(!changedAgain)
    }

    @Test func reconcileRemovesVanishedApps() {
        var model = LayoutModel(items: [.app("a"), .app("b"), .app("c")])
        model.reconcile(with: [app("a"), app("c")])
        #expect(model.items == [.app("a"), .app("c")])
    }

    @Test func reconcileDissolvesFolderBelowTwoMembers() {
        let folder = LayoutFolder(name: "Games", appIDs: ["g1", "g2", "g3"])
        var model = LayoutModel(items: [.app("a"), .folder(folder)])
        // Two members vanish → only g1 remains → folder dissolves.
        model.reconcile(with: [app("a"), app("g1")])
        #expect(model.items == [.app("a"), .app("g1")])
    }

    @Test func reconcileKeepsFolderWithTwoRemainingMembers() {
        let folder = LayoutFolder(name: "Games", appIDs: ["g1", "g2", "g3"])
        var model = LayoutModel(items: [.app("a"), .folder(folder)])
        model.reconcile(with: [app("a"), app("g1"), app("g3")])
        #expect(model.folder(id: folder.id)?.appIDs == ["g1", "g3"])
        #expect(model.items.count == 2)
    }

    @Test func reconcileDropsEmptyFolder() {
        let folder = LayoutFolder(name: "Gone", appIDs: ["g1", "g2"])
        var model = LayoutModel(items: [.app("a"), .folder(folder)])
        model.reconcile(with: [app("a")])
        #expect(model.items == [.app("a")])
    }

    // MARK: - Moves

    @Test func moveBeforeRef() {
        var model = LayoutModel(items: [.app("a"), .app("b"), .app("c")])
        let moved = model.move(.app("c"), before: .app("a"))
        #expect(moved)
        #expect(model.items == [.app("c"), .app("a"), .app("b")])
    }

    @Test func moveToEndWhenTargetMissing() {
        var model = LayoutModel(items: [.app("a"), .app("b")])
        let moved = model.move(.app("a"), before: nil)
        #expect(moved)
        #expect(model.items == [.app("b"), .app("a")])
    }

    @Test func moveAppOutOfFolderToGridPosition() {
        let folder = LayoutFolder(name: "F", appIDs: ["x", "y"])
        var model = LayoutModel(items: [.app("a"), .folder(folder), .app("b")])
        // Removing x leaves only y → folder dissolves; x lands before b.
        let moved = model.move(.app("x"), before: .app("b"))
        #expect(moved)
        #expect(model.items == [.app("a"), .app("y"), .app("x"), .app("b")])
    }

    // MARK: - Folders

    @Test func createFolderReplacesTargetPosition() {
        var model = LayoutModel(items: [.app("a"), .app("b"), .app("c")])
        let id = model.createFolder(with: "c", onto: "b")
        #expect(id != nil)
        #expect(model.items.count == 2)
        if case .folder(let folder) = model.items[1] {
            #expect(folder.appIDs == ["b", "c"])
        } else {
            Issue.record("expected folder at index 1")
        }
    }

    @Test func createFolderRejectsSameApp() {
        var model = LayoutModel(items: [.app("a")])
        let id = model.createFolder(with: "a", onto: "a")
        #expect(id == nil)
    }

    @Test func addAppToFolder() {
        let folder = LayoutFolder(name: "F", appIDs: ["x", "y"])
        var model = LayoutModel(items: [.folder(folder), .app("a")])
        let added = model.add(appID: "a", toFolder: folder.id)
        #expect(added)
        #expect(model.items.count == 1)
        #expect(model.folder(id: folder.id)?.appIDs == ["x", "y", "a"])
    }

    @Test func removeFromFolderDissolvesAtOneMember() {
        let folder = LayoutFolder(name: "F", appIDs: ["x", "y"])
        var model = LayoutModel(items: [.app("a"), .folder(folder), .app("b")])
        let removed = model.remove(appID: "x", fromFolder: folder.id)
        #expect(removed)
        #expect(model.items == [.app("a"), .app("y"), .app("x"), .app("b")])
        #expect(model.folder(id: folder.id) == nil)
    }

    @Test func removeFromFolderKeepsFolderWhenTwoRemain() {
        let folder = LayoutFolder(name: "F", appIDs: ["x", "y", "z"])
        var model = LayoutModel(items: [.folder(folder)])
        let removed = model.remove(appID: "z", fromFolder: folder.id)
        #expect(removed)
        #expect(model.folder(id: folder.id)?.appIDs == ["x", "y"])
    }

    @Test func dissolveFolderReturnsMembersInPlace() {
        let folder = LayoutFolder(name: "F", appIDs: ["x", "y"])
        var model = LayoutModel(items: [.app("a"), .folder(folder), .app("b")])
        let dissolved = model.dissolve(folderID: folder.id)
        #expect(dissolved)
        #expect(model.items == [.app("a"), .app("x"), .app("y"), .app("b")])
    }

    @Test func renameTrimsAndRejectsEmpty() {
        let folder = LayoutFolder(name: "Old", appIDs: ["x", "y"])
        var model = LayoutModel(items: [.folder(folder)])
        let renamed = model.rename(folderID: folder.id, to: "  New  ")
        #expect(renamed)
        #expect(model.folder(id: folder.id)?.name == "New")
        let emptied = model.rename(folderID: folder.id, to: "   ")
        #expect(emptied)
        #expect(model.folder(id: folder.id)?.name == LayoutFolder.defaultName)
    }

    // MARK: - Folder reordering

    @Test func moveInFolderBeforeTarget() {
        let folder = LayoutFolder(name: "F", appIDs: ["a", "b", "c", "d"])
        var model = LayoutModel(items: [.folder(folder)])
        let moved = model.moveInFolder(folderID: folder.id, appID: "d", before: "b")
        #expect(moved)
        #expect(model.folder(id: folder.id)?.appIDs == ["a", "d", "b", "c"])
    }

    @Test func moveInFolderTowardsEndUsesAdjustedIndex() {
        let folder = LayoutFolder(name: "F", appIDs: ["a", "b", "c", "d"])
        var model = LayoutModel(items: [.folder(folder)])
        let moved = model.moveInFolder(folderID: folder.id, appID: "a", before: "d")
        #expect(moved)
        #expect(model.folder(id: folder.id)?.appIDs == ["b", "c", "a", "d"])
    }

    @Test func moveInFolderRejectsSameOrUnknownApp() {
        let folder = LayoutFolder(name: "F", appIDs: ["a", "b"])
        var model = LayoutModel(items: [.folder(folder)])
        let same = model.moveInFolder(folderID: folder.id, appID: "a", before: "a")
        let unknownSource = model.moveInFolder(folderID: folder.id, appID: "nope", before: "a")
        let unknownTarget = model.moveInFolder(folderID: folder.id, appID: "a", before: "nope")
        #expect(!same)
        #expect(!unknownSource)
        #expect(!unknownTarget)
        #expect(model.folder(id: folder.id)?.appIDs == ["a", "b"])
    }

    // MARK: - Codable

    @Test func fileRoundTrip() throws {
        let folder = LayoutFolder(name: "F", appIDs: ["x", "y"])
        let model = LayoutModel(items: [.app("a"), .folder(folder), .app("b")])
        let data = try JSONEncoder().encode(model.file)
        let decoded = LayoutModel(file: try JSONDecoder().decode(LayoutFile.self, from: data))
        #expect(decoded == model)
    }

    // MARK: - Queries

    @Test func gridIndexFindsFolderContainingApp() {
        let folder = LayoutFolder(name: "F", appIDs: ["x", "y"])
        let model = LayoutModel(items: [.app("a"), .folder(folder)])
        #expect(model.gridIndex(containing: "y") == 1)
        #expect(model.contains(appID: "nope") == false)
    }
}
