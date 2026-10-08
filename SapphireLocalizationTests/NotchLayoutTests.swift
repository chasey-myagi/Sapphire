import XCTest
import SwiftUI
@testable import Sapphire

final class NotchLayoutTests: XCTestCase {
    func testHostDisplayBudgetKeepsCompactLogicalWidth() throws {
        let host = try XCTUnwrap(NSScreen.main)
        XCTAssertLessThanOrEqual(WidgetLayoutPolicy.availableBarWidth(for: host), min(720, host.frame.width - 48))
    }

    func testMusicAndCalendarConsumeTheirActualCardWidths() {
        XCTAssertEqual(WidgetLayoutPolicy.estimatedWidth(for: .music), 300)
        XCTAssertEqual(WidgetLayoutPolicy.estimatedWidth(for: .calendar), 240)
        XCTAssertEqual(WidgetLayoutPolicy.totalWidth(for: [.music, .calendar], showDividers: false), 560)
        XCTAssertEqual(WidgetLayoutPolicy.totalWidth(for: [.music, .calendar], showDividers: true), 581)
    }
    func testWidgetStripOwnsHorizontalScrollWhileFileShelfKeepsMenuSwipe() {
        XCTAssertFalse(NotchController.allowsMenuSwipe(mode: .defaultWidgets, navigationDepth: 1, enabled: true, isScrollHovered: true))
        XCTAssertTrue(NotchController.allowsMenuSwipe(mode: .defaultWidgets, navigationDepth: 1, enabled: true, isScrollHovered: false))
        XCTAssertTrue(NotchController.allowsMenuSwipe(mode: .fileShelf, navigationDepth: 1, enabled: true, isScrollHovered: false))
        XCTAssertFalse(NotchController.allowsMenuSwipe(mode: .fileShelf, navigationDepth: 1, enabled: false, isScrollHovered: false))
        XCTAssertFalse(NotchController.allowsMenuSwipe(mode: .fileShelf, navigationDepth: 2, enabled: true, isScrollHovered: false))
        XCTAssertFalse(NotchController.allowsMenuSwipe(mode: .musicPlayer, navigationDepth: 1, enabled: true, isScrollHovered: false))
    }

    func testLogicalDisplayWidthsBoundContentAndToolbarIntrinsicWidth() {
        for (screen, expected) in [(CGFloat(320), CGFloat(272)), (800, 720), (1512, 720), (3440, 720)] {
            XCTAssertEqual(WidgetLayoutPolicy.expandedWidthLimit(screenWidth: screen), expected)
            XCTAssertEqual(WidgetLayoutPolicy.boundedExpandedWidth(contentWidth: 10000, minimumWidth: 20000, screenWidth: screen), expected)
            XCTAssertEqual(WidgetLayoutPolicy.boundedExpandedWidth(contentWidth: 300, minimumWidth: 200, screenWidth: screen), min(300, expected))
        }
    }

    func testOverflowKeepsAllSupportedEnabledWidgetsAndSavedPreferences() throws {
        var settings = Settings()
        settings.widgetOrder = [.music, .calendar, .weather, .notes, .battery, .timer, .shortcuts, .clipboard, .mirror, .focusSession, .sports, .storage]
        settings.musicWidgetEnabled = true
        settings.calendarWidgetEnabled = true
        settings.weatherWidgetEnabled = true
        settings.notesWidgetEnabled = true
        settings.batteryWidgetEnabled = true
        settings.timerWidgetEnabled = true
        settings.shortcutsWidgetEnabled = true
        settings.clipboardWidgetEnabled = true
        settings.mirrorWidgetEnabled = true
        settings.focusSessionWidgetEnabled = true
        settings.sportsWidgetEnabled = true
        settings.storageWidgetEnabled = true
        for bypass in [false, true] {
            settings.bypassWidgetSpaceLimit = bypass
            let saved = try SettingsPersistence.encoder.encode(settings)
            let visible = WidgetLayoutPolicy.enabledWidgets(settings: settings, isMusicPlaying: true, isSpotifyPausedWithNoOtherPlayback: false)
            XCTAssertEqual(visible, Array(settings.widgetOrder.dropLast(2)))
            XCTAssertGreaterThan(WidgetLayoutPolicy.totalWidth(for: visible, showDividers: true), 720)
            XCTAssertEqual(try SettingsPersistence.encoder.encode(settings), saved)
        }
    }

    @MainActor
    func testRealStripFitsLongContentAndRemainsStableAcrossLayoutPasses() {
        let host = NSHostingView(rootView: BoundedWidgetStrip(maximumWidth: 300, initialWidth: 400) {
            HStack(spacing: 20) {
                Text(String(repeating: "Permission required 权限需要 ", count: 100))
                Color.blue.frame(width: 240, height: 100)
                Text("Last widget")
            }
        })
        assertStableLayout(host, expectedWidth: 300)
    }

    @MainActor
    func testRealStripHandlesEmptySingleAndMultipleCards() {
        for count in [0, 1, 5] {
            let host = NSHostingView(rootView: BoundedWidgetStrip(maximumWidth: 400, initialWidth: CGFloat(count * 120)) {
                HStack(spacing: 20) {
                    ForEach(0..<count, id: \.self) { _ in
                        Color.blue.frame(width: 120, height: 100)
                    }
                }
            })
            assertStableLayout(host, expectedWidth: max(1, min(400, CGFloat(count * 120 + max(0, count - 1) * 20))))
        }
    }

    @MainActor
    func testRealStripShrinksAndGrowsWithContentAndBudgetChanges() {
        func strip(count: Int, budget: CGFloat) -> some View {
            BoundedWidgetStrip(maximumWidth: budget, initialWidth: CGFloat(count * 120)) {
                HStack(spacing: 20) {
                    ForEach(0..<count, id: \.self) { _ in
                        Color.blue.frame(width: 120, height: 100)
                    }
                }
            }
        }
        let host = NSHostingView(rootView: strip(count: 5, budget: 400))
        for (count, budget, expectedWidth) in [(5, 400, 400), (5, 200, 200), (5, 720, 680), (1, 720, 120), (0, 720, 1), (5, 400, 400)] {
            host.rootView = strip(count: count, budget: CGFloat(budget))
            assertStableLayout(host, expectedWidth: CGFloat(expectedWidth))
            XCTAssertEqual(host.fittingSize.height, count == 0 ? 1 : 100, accuracy: 1)
        }
    }

    @MainActor
    func testRealNativeScrollCanReachLastOverflowCard() throws {
        let host = NSHostingView(rootView: BoundedWidgetStrip(maximumWidth: 300, initialWidth: 680) {
            HStack(spacing: 20) {
                ForEach(0..<5, id: \.self) { _ in
                    Color.blue.frame(width: 120, height: 100)
                }
            }
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        assertStableLayout(host, expectedWidth: 300)
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        print("NATIVE_SCROLL", document.frame, document.bounds, scroll.contentView.bounds, scroll.contentView.documentRect)
        let maximumOffset = document.bounds.width - scroll.contentView.bounds.width
        XCTAssertGreaterThan(maximumOffset, 0)
        scroll.contentView.scroll(to: CGPoint(x: maximumOffset, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.maxX, document.bounds.maxX, accuracy: 1)
    }

    @MainActor
    func testRealToolbarKeepsViewportsOutsidePhysicalCutout() throws {
        let physicalCutout: CGFloat = 185
        let reservedGap: CGFloat = 189
        let host = NSHostingView(rootView: NotchToolbarLayout(
            width: 720, height: 40, horizontalPadding: 40, cutoutWidth: reservedGap,
            isScrollHovered: .constant(false),
            gear: Button {} label: { Text("Gear").frame(width: 32, height: 24) }.buttonStyle(.plain),
            left: HStack(spacing: 0) { ForEach(0..<10) { index in Text("L\(index)").frame(width: 40, height: 24) } }.fixedSize(),
            right: HStack(spacing: 0) { ForEach(0..<10) { index in Text("R\(index)").frame(width: 40, height: 24) } }.fixedSize()
        ))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            if let scroll = view as? NSScrollView { return [scroll] }
            return view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scrolls = scrollViews(in: host).sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
        XCTAssertEqual(scrolls.count, 2)
        guard scrolls.count == 2 else { return }
        let left = scrolls[0].convert(scrolls[0].bounds, to: host)
        let right = scrolls[1].convert(scrolls[1].bounds, to: host)
        XCTAssertLessThanOrEqual(left.maxX, 720 / 2 - physicalCutout / 2)
        XCTAssertGreaterThanOrEqual(right.minX, 720 / 2 + physicalCutout / 2)
    }

    @MainActor
    func testRealToolbarGearAndBothScrollEndpointsStayVisibleOnNarrowAndNotchlessPanels() throws {
        // Hardware measurement reserves four points beyond the physical cutout.
        for (width, physicalCutout, reservedGap) in [(CGFloat(720), CGFloat(185), CGFloat(189)), (480, 185, 189), (272, 0, 0)] {
            let host = NSHostingView(rootView: NotchToolbarLayout(
                width: width, height: 40, horizontalPadding: 40, cutoutWidth: reservedGap,
                isScrollHovered: .constant(false),
                gear: SubtleIconButton(systemName: "gearshape", action: {}).background(ToolbarTestMarker(name: "gear")),
                left: HStack(spacing: 0) {
                    ForEach(0..<10) { index in
                        Button {} label: { Text("L\(index)").frame(width: 40, height: 24).background(ToolbarTestMarker(name: "L\(index)")) }
                            .buttonStyle(.plain)
                    }
                }.fixedSize(),
                right: HStack(spacing: 0) {
                    ForEach(0..<10) { index in
                        Button {} label: { Text("R\(index)").frame(width: 40, height: 24).background(ToolbarTestMarker(name: "R\(index)")) }
                            .buttonStyle(.plain)
                    }
                }.fixedSize()
            ))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            func settle() {
                for _ in 0..<12 {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
            }
            settle()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            let views = descendants(host)
            let gear = try XCTUnwrap(views.first { $0.identifier?.rawValue == "gear" })
            let gearBounds = gear.convert(gear.bounds, to: host)
            XCTAssertGreaterThan(gearBounds.width, 20)
            XCTAssertGreaterThanOrEqual(gearBounds.minX, 0)
            XCTAssertLessThanOrEqual(gearBounds.maxX, width / 2 - physicalCutout / 2)
            let scrolls = views.compactMap { $0 as? NSScrollView }.sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
            XCTAssertEqual(scrolls.count, 2)
            for (index, scroll) in scrolls.enumerated() {
                let clip = scroll.contentView
                let viewport = clip.convert(clip.bounds, to: host)
                XCTAssertGreaterThan(viewport.width, 0)
                XCTAssertGreaterThan(viewport.height, 0)
                XCTAssertGreaterThanOrEqual(viewport.minX, 0)
                XCTAssertLessThanOrEqual(viewport.maxX, width)
                if index == 0 { XCTAssertLessThanOrEqual(viewport.maxX, width / 2 - physicalCutout / 2) }
                else { XCTAssertGreaterThanOrEqual(viewport.minX, width / 2 + physicalCutout / 2) }
                let prefix = index == 0 ? "L" : "R"
                let first = try XCTUnwrap(views.first { $0.identifier?.rawValue == prefix + "0" })
                let last = try XCTUnwrap(views.first { $0.identifier?.rawValue == prefix + "9" })
                let document = try XCTUnwrap(scroll.documentView)
                for (offset, item) in [(CGFloat(0), first), (document.bounds.width - clip.bounds.width, last)] {
                    clip.scroll(to: CGPoint(x: offset, y: 0))
                    scroll.reflectScrolledClipView(clip)
                    let bounds = item.convert(item.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(bounds.minX, viewport.minX - 1)
                    XCTAssertLessThanOrEqual(bounds.maxX, viewport.maxX + 1)
                }
            }

        }
    }

    @MainActor
    private func assertStableLayout<Content: View>(_ host: NSHostingView<Content>, expectedWidth: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        host.frame = CGRect(x: 0, y: 0, width: 10000, height: 1000)
        var sizes: [CGSize] = []
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            sizes.append(host.fittingSize)
        }
        for size in sizes.suffix(4) {
            XCTAssertTrue(size.width.isFinite && size.height.isFinite, file: file, line: line)
            XCTAssertEqual(size.width, expectedWidth, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThan(size.height, 0, file: file, line: line)
            XCTAssertEqual(size.height, sizes.last!.height, accuracy: 1, file: file, line: line)
        }
    }
}

private struct ToolbarTestMarker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
