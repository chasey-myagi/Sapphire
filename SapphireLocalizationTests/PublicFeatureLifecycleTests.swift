import XCTest
@testable import Sapphire

final class PublicFeatureLifecycleTests: XCTestCase {
    @MainActor
    func testPublicSportsLifecycleNeverSchedulesOrFetchesWhenSavedPreferencesToggle() async throws {
        var scheduledIntervals: [TimeInterval] = []
        var bootstrapCount = 0
        var refreshCount = 0
        var tickCount = 0
        let watcher = SportsActivityWatcher(
            bootstrap: { bootstrapCount += 1 },
            refresh: { refreshCount += 1 },
            onTick: { tickCount += 1 },
            schedule: { interval, _ in
                scheduledIntervals.append(interval)
                // Do not attach even a regressed timer to a real run loop.
                return Timer(timeInterval: interval, repeats: true) { _ in }
            }
        )
        defer { watcher.stop() }

        for enabled in [false, true] {
            var saved = Settings()
            saved.sportsWidgetEnabled = enabled
            saved.storageWidgetEnabled = enabled
            saved.sportsLiveActivityEnabled = enabled
            saved.menuBarProfilesEnabled = enabled
            var settings = try XCTUnwrap(SettingsPersistence.decodeFromPayload(SettingsPersistence.encoder.encode(saved)))
            for choice in [enabled, !enabled, enabled] {
                settings.sportsLiveActivityEnabled = choice
                let before = try SettingsPersistence.encoder.encode(settings)
                for onScreen in [false, true, false] {
                    watcher.update(enabled: settings.sportsLiveActivityEnabled, isOnScreen: onScreen)
                    watcher.update(enabled: settings.sportsLiveActivityEnabled, isOnScreen: onScreen)
                }
                watcher.stop()
                watcher.stop()
                await Task.yield()
                XCTAssertTrue(scheduledIntervals.isEmpty, "Unavailable sports must never create a polling timer")
                XCTAssertEqual(bootstrapCount, 0)
                XCTAssertEqual(refreshCount, 0)
                XCTAssertEqual(tickCount, 0)
                XCTAssertEqual(try SettingsPersistence.encoder.encode(settings), before)
            }
        }
    }

    func testPublicWidgetsExcludeUnavailableContentAndPreserveSavedChoicesAndOrder() throws {
        for enabled in [false, true] {
            var saved = Settings()
            saved.sportsWidgetEnabled = enabled
            saved.storageWidgetEnabled = enabled
            saved.sportsLiveActivityEnabled = enabled
            saved.menuBarProfilesEnabled = enabled
            saved.widgetOrder = [.notes, .sports, .music, .storage, .calendar, .timer, .battery]
            saved.notesWidgetEnabled = true
            saved.musicWidgetEnabled = true
            saved.calendarWidgetEnabled = true
            saved.timerWidgetEnabled = false
            saved.batteryWidgetEnabled = true
            saved.weatherWidgetEnabled = false
            saved.focusSessionWidgetEnabled = false
            let settings = try XCTUnwrap(SettingsPersistence.decodeFromPayload(SettingsPersistence.encoder.encode(saved)))
            let before = try SettingsPersistence.encoder.encode(settings)
            let visible = WidgetLayoutPolicy.enabledWidgets(
                settings: settings,
                isMusicPlaying: true,
                isSpotifyPausedWithNoOtherPlayback: false
            )
            XCTAssertEqual(visible, [.notes, .music, .calendar, .battery])
            XCTAssertFalse(visible.contains(.sports))
            XCTAssertFalse(visible.contains(.storage))
            XCTAssertFalse(visible.contains(.timer))
            XCTAssertEqual(try SettingsPersistence.encoder.encode(settings), before)
            XCTAssertEqual(settings.sportsWidgetEnabled, enabled)
            XCTAssertEqual(settings.storageWidgetEnabled, enabled)
            XCTAssertEqual(settings.sportsLiveActivityEnabled, enabled)
            XCTAssertEqual(settings.menuBarProfilesEnabled, enabled)
        }
    }

    func testPublicWidgetSelectionKeepsMusicPlaybackVisibilityRules() {
        var settings = Settings()
        settings.widgetOrder = [.notes, .music]
        settings.notesWidgetEnabled = true
        settings.musicWidgetEnabled = true
        settings.hideMusicWidgetWhenNotPlaying = true
        XCTAssertEqual(WidgetLayoutPolicy.enabledWidgets(settings: settings, isMusicPlaying: false, isSpotifyPausedWithNoOtherPlayback: false), [.notes])
        XCTAssertEqual(WidgetLayoutPolicy.enabledWidgets(settings: settings, isMusicPlaying: true, isSpotifyPausedWithNoOtherPlayback: false), [.notes, .music])
        settings.hideMusicWidgetWhenNotPlaying = false
        settings.hideMusicWidgetWhenSpotifyPausedAndIdle = true
        XCTAssertEqual(WidgetLayoutPolicy.enabledWidgets(settings: settings, isMusicPlaying: false, isSpotifyPausedWithNoOtherPlayback: true), [.notes])
        settings.musicWidgetEnabled = false
        XCTAssertEqual(WidgetLayoutPolicy.enabledWidgets(settings: settings, isMusicPlaying: true, isSpotifyPausedWithNoOtherPlayback: false), [.notes])
    }

    func testUnavailableMenuBarProfilesRemainInactiveWithoutChangingSavedPreferences() throws {
        for enabled in [false, true] {
            var settings = Settings()
            settings.menuBarProfilesEnabled = enabled
            let before = try SettingsPersistence.encoder.encode(settings)
            let engine = MenuBarProfileEngine.shared
            for _ in 0..<3 {
                engine.start()
                engine.refresh()
                XCTAssertFalse(engine.isRevealRequested)
                engine.stop()
                XCTAssertFalse(engine.isRevealRequested)
            }
            XCTAssertTrue(MenuBarProfileEngine.fetchAvailableFocusModes().isEmpty)
            XCTAssertEqual(try SettingsPersistence.encoder.encode(settings), before)
        }
    }
}
