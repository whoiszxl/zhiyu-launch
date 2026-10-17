import AppKit

/// Built-in UI smoke test (`ZHIYU_UITEST=1`).
///
/// Feeds synthesized keyboard and scroll events through the real responder chain
/// and asserts on the controller's probe state. Covers the interaction paths unit
/// tests cannot reach: focus routing, type-to-search, paging (wheel / trackpad
/// style / page dots), selection movement, Escape handling and the folder overlay.
///
/// Mouse clicks are exercised via their handler entry points instead of synthetic
/// mouse events: AppKit routes mouse-ups to the target recorded on mouse-down, so
/// a bare synthesized mouse-up (without a real event-tracking session) is not
/// reliably delivered. Real clicks always arrive as a down/up pair.
///
/// The layout it creates while testing is restored before exiting.
@MainActor
final class UITestRunner {
    private let controller: LaunchpadController
    private var failures: [String] = []
    private var steps: [(name: String, delay: TimeInterval, body: () -> Void)] = []
    private var stepIndex = 0

    init(controller: LaunchpadController) {
        self.controller = controller
    }

    func run() {
        log("runner started")
        // Stray system mouse events (real input devices) must not close the panel
        // mid-test; the real background-click behavior is verified by a dedicated
        // step later on.
        controller.probeIgnoresBackgroundClose = true
        if !controller.isVisible {
            controller.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start()
        }
    }

    private func start() {
        guard let viewController = controller.probeViewController else {
            failures.append("no view controller")
            finish()
            return
        }
        steps = buildSteps(viewController)
        executeNext()
    }

    private func executeNext() {
        guard stepIndex < steps.count else {
            finish()
            return
        }
        let step = steps[stepIndex]
        stepIndex += 1
        step.body()
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self] in
            self?.executeNext()
        }
    }

    private func finish() {
        if failures.isEmpty {
            NSLog("[ZhiyuLaunch] UITEST: ALL PASS (\(stepIndex) steps)")
        } else {
            NSLog("[ZhiyuLaunch] UITEST: \(failures.count) FAILURES: \(failures.joined(separator: "; "))")
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private func check(_ name: String, _ condition: Bool, detail: @autoclosure () -> String = "") {
        if condition {
            NSLog("[ZhiyuLaunch] UITEST PASS: \(name)")
        } else {
            failures.append(name)
            NSLog("[ZhiyuLaunch] UITEST FAIL: \(name) [\(detail())]")
        }
    }

    private func log(_ message: String) {
        NSLog("[ZhiyuLaunch] UITEST: \(message)")
    }

    // MARK: - Steps

    private func buildSteps(_ viewController: LaunchpadViewController) -> [(name: String, delay: TimeInterval, body: () -> Void)] {
        let layoutState = controller.probeLayoutState
        let originalModel = layoutState.model
        let originalCount = viewController.probeState.cellCount
        var steps: [(name: String, delay: TimeInterval, body: () -> Void)] = []

        steps.append(("initial state", 0.1, {
            let state = viewController.probeState
            self.check("grid populated", state.cellCount > 5, detail: "cells=\(state.cellCount)")
            self.check("starts on page 0", state.currentPage == 0, detail: "page=\(state.currentPage)")
            self.check("has pages", state.pageCount > 1, detail: "pages=\(state.pageCount)")
            self.check("first cell selected", state.selectedIndex == 0, detail: "sel=\(String(describing: state.selectedIndex))")
        }))

        steps.append(("non-animated jump to page 1", 0.2, {
            viewController.probeJumpNoAnimation(to: 1)
            self.check("no-animation jump works", viewController.probeState.currentPage == 1,
                       detail: "page=\(viewController.probeState.currentPage)")
            viewController.probeJumpNoAnimation(to: 0)
        }))

        steps.append(("recent strip shows seeded apps", 0.2, {
            self.check("recent strip has items", viewController.probeRecentCount >= 2,
                       detail: "count=\(viewController.probeRecentCount)")
            self.check("recent strip visible on page 0", viewController.probeRecentStripVisible)
        }))

        steps.append(("recent strip hides off the first page", 0.2, {
            viewController.probeJumpNoAnimation(to: 1)
            self.check("strip hidden on page 1", !viewController.probeRecentStripVisible)
            viewController.probeJumpNoAnimation(to: 0)
        }))

        steps.append(("recent strip returns on page 0", 0.1, {
            self.check("strip visible again", viewController.probeRecentStripVisible)
        }))

        steps.append(("type to search", 0.5, {
            self.typeForSearch("saf", in: viewController)
        }))

        steps.append(("search filters grid", 0.1, {
            let state = viewController.probeState
            self.check("query captured", state.query == "saf", detail: "query='\(state.query)'")
            self.check("results filtered", !state.names.isEmpty && state.names.allSatisfy { $0.lowercased().contains("saf") },
                       detail: "names=\(state.names)")
        }))

        steps.append(("esc clears query", 0.4, {
            self.pressKey("\u{1B}", keyCode: 53, in: viewController)
        }))

        steps.append(("grid restored", 0.1, {
            let state = viewController.probeState
            self.check("query cleared", state.query.isEmpty, detail: "query='\(state.query)'")
            self.check("cells restored", state.cellCount == originalCount, detail: "cells=\(state.cellCount) vs \(originalCount)")
        }))

        steps.append(("selection moves", 0.3, {
            self.pressKey(self.functionKey(0xF703), keyCode: 124, in: viewController) // right arrow
        }))

        steps.append(("selection moved", 0.1, {
            self.check("selected index 1", viewController.probeState.selectedIndex == 1,
                       detail: "sel=\(String(describing: viewController.probeState.selectedIndex))")
            self.pressKey(self.functionKey(0xF702), keyCode: 123, in: viewController) // left arrow
        }))

        steps.append(("selection back", 0.1, {
            self.check("selected index 0", viewController.probeState.selectedIndex == 0,
                       detail: "sel=\(String(describing: viewController.probeState.selectedIndex))")
        }))

        steps.append(("partial trackpad swipe snaps back", 0.7, {
            // Less than half a page of travel must snap back to the start page.
            self.sendScroll(dy: -200, precise: true, phase: 1, to: viewController) // began
            self.sendScroll(dy: -100, precise: true, phase: 4, to: viewController) // changed (~0.2 page)
            self.sendScroll(dy: 0, precise: true, phase: 8, to: viewController)    // ended
        }))

        steps.append(("back on page 0 after partial swipe", 0.1, {
            self.check("snapped back to page 0", viewController.probeState.currentPage == 0,
                       detail: "page=\(viewController.probeState.currentPage)")
        }))

        steps.append(("wheel down flips page", 0.7, {
            self.sendScroll(dy: -1, precise: false, to: viewController)
        }))

        steps.append(("page 1 visible", 0.1, {
            self.check("on page 1", viewController.probeState.currentPage == 1,
                       detail: "page=\(viewController.probeState.currentPage)")
        }))

        steps.append(("vertical trackpad swipe flips page", 0.7, {
            // Live-follow gesture: begin, travel more than half a page, end.
            self.sendScroll(dy: -400, precise: true, phase: 1, to: viewController) // began
            self.sendScroll(dy: -400, precise: true, phase: 4, to: viewController) // changed
            self.sendScroll(dy: 0, precise: true, phase: 8, to: viewController)    // ended
        }))

        steps.append(("page 2 visible", 0.1, {
            self.check("on page 2", viewController.probeState.currentPage == 2,
                       detail: "page=\(viewController.probeState.currentPage)")
        }))

        steps.append(("wheel up goes back", 0.7, {
            self.sendScroll(dy: 1, precise: false, to: viewController)
        }))

        steps.append(("page 1 again", 0.1, {
            self.check("back on page 1", viewController.probeState.currentPage == 1,
                       detail: "page=\(viewController.probeState.currentPage)")
        }))

        steps.append(("select page 0 via indicator", 0.7, {
            viewController.probeIndicator.probeSelect(page: 0)
        }))

        steps.append(("dot click jumps to page 0", 0.1, {
            self.check("jumped to page 0", viewController.probeState.currentPage == 0,
                       detail: "page=\(viewController.probeState.currentPage)")
        }))

        steps.append(("end key jumps to last page", 0.8, {
            self.pressKey(self.functionKey(0xF72B), keyCode: 119, in: viewController) // End
        }))

        steps.append(("on last page", 0.1, {
            let state = viewController.probeState
            self.check("on last page", state.currentPage == state.pageCount - 1,
                       detail: "page=\(state.currentPage)/\(state.pageCount - 1)")
        }))

        steps.append(("home key jumps to first page", 0.8, {
            self.pressKey(self.functionKey(0xF729), keyCode: 115, in: viewController) // Home
        }))

        steps.append(("back on first page", 0.1, {
            self.check("on first page", viewController.probeState.currentPage == 0,
                       detail: "page=\(viewController.probeState.currentPage)")
        }))

        steps.append(("hide an app", 0.3, {
            let before = viewController.probeState.cellCount
            viewController.probeHideCell(at: 1)
            self.check("cell count dropped after hide", viewController.probeState.cellCount == before - 1,
                       detail: "before=\(before) after=\(viewController.probeState.cellCount)")
        }))

        steps.append(("unhide restores the app", 0.3, {
            viewController.probeUnhideAll()
            self.check("cell count restored after unhide", viewController.probeState.cellCount == originalCount,
                       detail: "cells=\(viewController.probeState.cellCount)")
        }))

        steps.append(("simulated reorder drop", 0.4, {
            let idsBefore = viewController.probeCellIDs
            guard idsBefore.count > 4, let target = viewController.probeCellWindowFrame(at: 4) else {
                self.failures.append("no frames for reorder")
                return
            }
            let movedID = idsBefore[2]
            let accepted = viewController.probePerformDrop(
                sourceIndex: 2,
                atWindowPoint: NSPoint(x: target.minX + 6, y: target.midY) // left edge → insert before
            )
            self.check("reorder drop accepted", accepted)
            let idsAfter = viewController.probeCellIDs
            self.check("reorder applied", idsAfter.count == idsBefore.count && idsAfter.firstIndex(of: movedID) == 3,
                       detail: "after=\(idsAfter.prefix(6))")
        }))

        steps.append(("drag app onto app creates folder", 0.5, {
            guard viewController.probeCellIDs.count > 1,
                  let target = viewController.probeCellWindowFrame(at: 0) else {
                self.failures.append("no frames for folder drop")
                return
            }
            let accepted = viewController.probePerformDrop(
                sourceIndex: 1,
                atWindowPoint: NSPoint(x: target.midX, y: target.midY) // center → folder
            )
            self.check("folder drop accepted", accepted)
        }))

        steps.append(("folder cell appears", 0.3, {
            self.check("first cell is folder", viewController.probeFirstCellIsFolder)
            self.check("cell count dropped", viewController.probeState.cellCount == originalCount - 1,
                       detail: "cells=\(viewController.probeState.cellCount)")
        }))

        steps.append(("activate folder cell", 0.5, {
            viewController.activateCell(at: 0)
        }))

        steps.append(("folder overlay presented", 0.3, {
            self.check("overlay presented", viewController.probeState.isFolderPresented)
        }))

        steps.append(("arrow key navigates folder tiles", 0.3, {
            self.pressKey(self.functionKey(0xF703), keyCode: 124, in: viewController) // right arrow
        }))

        steps.append(("folder selection moved", 0.1, {
            self.check("folder tile 1 selected", viewController.probeFolderSelection == 1,
                       detail: "sel=\(String(describing: viewController.probeFolderSelection))")
        }))

        steps.append(("wheel while folder is open", 0.2, {
            // Wheel input must scroll the folder, never flip the grid behind it.
            self.sendScroll(dy: -1, precise: false, to: viewController)
        }))

        steps.append(("grid page unchanged while folder open", 0.1, {
            self.check("page stays 0", viewController.probeState.currentPage == 0,
                       detail: "page=\(viewController.probeState.currentPage)")
        }))

        steps.append(("esc closes folder", 0.5, {
            self.pressKey("\u{1B}", keyCode: 53, in: viewController)
        }))

        steps.append(("overlay dismissed", 0.2, {
            self.check("overlay dismissed", !viewController.probeState.isFolderPresented)
        }))

        steps.append(("drag app into folder adds it", 0.5, {
            guard let target = viewController.probeCellWindowFrame(at: 0) else {
                self.failures.append("no frames for add-to-folder drop")
                return
            }
            let accepted = viewController.probePerformDrop(
                sourceIndex: 1,
                atWindowPoint: NSPoint(x: target.midX, y: target.midY)
            )
            self.check("add-to-folder drop accepted", accepted)
            var memberCount = -1
            if case .folder(let folder) = layoutState.model.items.first {
                memberCount = folder.appIDs.count
            }
            self.check("folder now holds 3 apps", memberCount == 3, detail: "members=\(memberCount)")
        }))

        steps.append(("restore layout", 0.3, {
            layoutState.mutate { model -> Bool in
                guard model != originalModel else { return false }
                model = originalModel
                return true
            }
            layoutState.saveNow()
            viewController.probeReload()
        }))

        steps.append(("layout restored", 0.2, {
            self.check("cell count restored", viewController.probeState.cellCount == originalCount,
                       detail: "cells=\(viewController.probeState.cellCount)")
        }))

        steps.append(("drag near right edge starts a page flip", 0.9, {
            let bounds = viewController.view.bounds
            viewController.probeUpdateEdgeFlip(atWindowPoint: NSPoint(x: bounds.width - 20, y: bounds.midY))
            self.check("edge flip scheduled", viewController.probeEdgeFlipPending)
        }))

        steps.append(("edge flip advances the page", 0.1, {
            self.check("page advanced to 1", viewController.probeState.currentPage == 1,
                       detail: "page=\(viewController.probeState.currentPage)")
            // Park at a neutral position, then return to page 0 for the close test.
            let bounds = viewController.view.bounds
            viewController.probeUpdateEdgeFlip(atWindowPoint: NSPoint(x: bounds.midX, y: bounds.midY))
            viewController.probeJumpNoAnimation(to: 0)
        }))

        steps.append(("background click closes panel", 0.6, {
            viewController.probeIgnoresBackgroundClose = false
            viewController.probeBackgroundClick()
        }))

        steps.append(("panel hidden", 0.3, {
            self.check("panel hidden", !self.controller.isVisible)
        }))

        steps.append(("reopen for command-W test", 1.0, {
            self.controller.show()
        }))

        steps.append(("command-W closes panel", 0.7, {
            // Key equivalents are handled by the main menu; events must go through
            // the application's dispatcher for that path to run.
            guard let window = viewController.view.window,
                  let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: "w",
                    charactersIgnoringModifiers: "w",
                    isARepeat: false,
                    keyCode: 13
                  ) else { return }
            NSApp.sendEvent(event)
        }))

        steps.append(("panel hidden after command-W", 0.3, {
            self.check("panel hidden by command-W", !self.controller.isVisible)
        }))

        return steps
    }

    // MARK: - Event synthesis

    private func functionKey(_ scalar: UInt32) -> String {
        String(UnicodeScalar(scalar) ?? " ")
    }

    /// Types into the search field through the field editor's `insertText`.
    ///
    /// Synthesized `keyDown` events are unreliable in tests when a third-party
    /// input method (e.g. a pinyin IME) is active — the IME intercepts key codes
    /// and produces different text. `insertText` is exactly what the field editor
    /// calls after the IME commits, so the app's own code path
    /// (controlTextDidChange → applySearch) is still fully exercised.
    private func typeForSearch(_ text: String, in viewController: LaunchpadViewController) {
        guard let editor = viewController.probeSearchFieldEditor else {
            failures.append("no search field editor")
            log("type failed: no field editor")
            return
        }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func pressKey(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in viewController: LaunchpadViewController) {
        guard let window = viewController.view.window else { return }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        window.sendEvent(event)
    }

    /// Synthesizes a trackpad/wheel scroll event.
    /// `phase` uses NSEventPhase raw values: 1 = began, 4 = changed, 8 = ended.
    private func sendScroll(dy: Int32, precise: Bool, phase: Int64 = 0, to viewController: LaunchpadViewController) {
        let units: CGScrollEventUnit = precise ? .pixel : .line
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
        if precise {
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if phase != 0 {
                cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            }
        }
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        log("scroll: precise=\(event.hasPreciseScrollingDeltas) phase=\(event.phase.rawValue) delta=(\(event.scrollingDeltaX), \(event.scrollingDeltaY)) pageBefore=\(viewController.probeState.currentPage)")
        viewController.probeCollectionView.scrollWheel(with: event)
    }
}
