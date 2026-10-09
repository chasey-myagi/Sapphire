import XCTest
@testable import Sapphire

final class FileProgressIntegrationTests: XCTestCase {
    @MainActor
    func testFileTaskChangesDriveActivityAndStopDetachesObserver() async throws {
        try await withFileProgressFixture { manager, fileDrop in
            var task = AirDropTask(fileName: "integration-only.txt", progress: 0.1)
            fileDrop.tasks = [.airDrop(task)]
            try await self.remainIdle(manager, scenario: "disabled file progress ignores tasks")
            fileDrop.tasks = []
            try await self.enableFileProgressAndSettle(manager)

            fileDrop.tasks = [.airDrop(task)]
            try await self.observe("FILE_PROGRESS_TASK_DID_NOT_APPEAR: new task enters file progress") {
                manager.currentActivity == .fileProgress && self.airDrop(in: manager.activityContent) == task
            }

            task.progress = 0.8
            fileDrop.tasks = [.airDrop(task)]
            try await self.observe("same task updates displayed progress") {
                manager.currentActivity == .fileProgress && self.airDrop(in: manager.activityContent) == task
            }

            manager.stop()
            task.progress = 0.2
            fileDrop.tasks = [.airDrop(task)]
            // Longer than the real throttle, evaluator gate and dismissal grace.
            // Any subscription left alive would introduce the task again.
            try await self.remainIdle(manager, scenario: "stopped manager ignores tasks")
        }
    }

    // Reproduces the retained baseline completion-dismissal defect. The scoped
    // subscription CI job selects the method above; this separate case keeps the
    // real expected behavior and failing assertion available for defect work.
    @MainActor
    func testCompletedFileTaskDismissesActivity() async throws {
        try await withFileProgressFixture { manager, fileDrop in
            try await self.enableFileProgressAndSettle(manager)
            var task = AirDropTask(fileName: "completion-reproduction.txt", progress: 0.1)
            fileDrop.tasks = [.airDrop(task)]
            try await self.observe("FILE_PROGRESS_TASK_DID_NOT_APPEAR: completion precondition") {
                manager.currentActivity == .fileProgress && self.airDrop(in: manager.activityContent) == task
            }

            task.isComplete = true
            fileDrop.tasks = [.airDrop(task)]
            try await self.observe("completed task releases file progress") {
                manager.currentActivity == .none && manager.activityContent == .none
            }
        }
    }

    @MainActor
    private func withFileProgressFixture(
        _ body: (LiveActivityManager, FileDropManager) async throws -> Void
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SAPPHIRE_FILE_PROGRESS_INTEGRATION"] == "1",
              environment["GITHUB_ACTIONS"] == "true" else {
            throw XCTSkip("Requires the dedicated disposable GitHub-hosted macOS integration job; real service constructors are not safe on a personal host.")
        }

        // Seed storage before any shared service reads settings. The dedicated job
        // selects an integration case; its account and service data are disposable.
        var settings = Settings()
        settings.liveActivityOrder = [.fileProgress]
        settings.fileProgressLiveActivityEnabled = false
        settings.fileShelfLiveActivityEnabled = false
        settings.musicLiveActivityEnabled = false
        settings.weatherLiveActivityEnabled = false
        settings.calendarLiveActivityEnabled = false
        settings.remindersLiveActivityEnabled = false
        settings.timersLiveActivityEnabled = false
        settings.batteryLiveActivityEnabled = false
        settings.eyeBreakLiveActivityEnabled = false
        settings.desktopLiveActivityEnabled = false
        settings.focusLiveActivityEnabled = false
        settings.focusSessionLiveActivityEnabled = false
        settings.microphoneLiveActivityEnabled = false
        settings.bluetoothLiveActivityEnabled = false
        settings.statsLiveActivityEnabled = false
        settings.statsLiveActivityThresholdEnabled = false
        settings.showPersistentStatsLiveActivity = false
        settings.showPersistentBatteryLiveActivity = false
        settings.showPersistentWeatherLiveActivity = false
        settings.sportsLiveActivityEnabled = false
        settings.devActivityEnabled = false
        settings.caffeinateAutoDuringTasks = false
        settings.masterNotificationsEnabled = false
        settings.parcelTrackingEnabled = false
        settings.parcelLiveActivityEnabled = false
        settings.otpLiveActivityEnabled = false
        settings.neardropEnabled = false
        settings.hapticFeedbackEnabled = false
        settings.updateAvailableNotificationsEnabled = false
        settings.showUpdateAvailableLiveActivity = false
        settings.enableVolumeHUD = false
        settings.enableBrightnessHUD = false
        settings.hideLiveActivityInFullScreen = false
        UserDefaults.standard.set(
            try SettingsPersistence.encoder.encode(settings),
            forKey: SettingsPersistence.payloadKey
        )
        // Reset an already loaded model when both cases run in one test process.
        SettingsModel.shared.settings = settings

        let delegate = AppDelegate()
        let manager = delegate.liveActivityManager
        let fileDrop = FileDropManager.shared
        fileDrop.tasks = []
        defer {
            manager.stop()
            fileDrop.tasks = []
            DownloadMonitor.shared.stopMonitoring()
        }

        manager.start()
        // Let initial publisher deliveries and the evaluator's background-work
        // gate settle before the task that must independently cause evaluation.
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(manager.currentActivity, .none)
        XCTAssertEqual(manager.activityContent, .none)
        XCTAssertTrue(fileDrop.tasks.isEmpty)
        try await body(manager, fileDrop)
    }

    @MainActor
    private func enableFileProgressAndSettle(_ manager: LiveActivityManager) async throws {
        SettingsModel.shared.settings.fileProgressLiveActivityEnabled = true
        // The settings publisher also reevaluates activities. Drain it with no
        // task present so it cannot stand in for the task-change subscription.
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(manager.currentActivity, .none)
        XCTAssertEqual(manager.activityContent, .none)
    }

    @MainActor
    private func observe(_ scenario: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out observing the real production path: \(scenario)")
        throw ObservationTimeout()
    }

    @MainActor
    private func remainIdle(_ manager: LiveActivityManager, scenario: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            XCTAssertEqual(manager.currentActivity, .none, scenario)
            XCTAssertEqual(manager.activityContent, .none, scenario)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func airDrop(in content: LiveActivityContent) -> AirDropTask? {
        guard case .standard(let data, _) = content,
              case .fileProgress(let task) = data,
              case .airDrop(let airDrop) = task else { return nil }
        return airDrop
    }

    private struct ObservationTimeout: Error {}
}
