import AppKit
import Combine
import XCTest
@testable import Sapphire

/// The basic music controls kept after the third-party integrations were removed:
/// command routing, play-state hold, source selection, shuffle/repeat state and the
/// HUD's app volume slider.
///
/// The fake controller follows `NativeMediaController`'s contract: one app owns system
/// Now Playing at a time. Every sequence here is one the real controller can produce,
/// i.e. a series of hand-offs and clears. Because of that contract there is never more
/// than one source to choose from, so a user pin cannot outlast a hand-off and a
/// selected Spotify that does not own Now Playing exists only until the deferred
/// callback work runs. The tests drive that work explicitly through `callbacks`.
@MainActor
final class MusicRetainedControlTests: XCTestCase {
    private static let spotify = "com.spotify.client"
    private static let finder = "com.apple.finder"
    /// The test host is a running app, which the source filter requires.
    private static var host: String { Bundle.main.bundleIdentifier ?? "com.cshariq.sapphire" }

    private var controller: RecordingMediaController!
    private var script: RecordingSpotifyScript!
    private var callbacks: ManualMainQueue!
    private var clock: TestClock!
    private var manager: MusicManager!

    override func setUp() async throws {
        controller = RecordingMediaController()
        script = RecordingSpotifyScript()
        callbacks = ManualMainQueue()
        clock = TestClock()
        var settings = Settings()
        settings.mediaSource = .system
        settings.prioritizeMediaSource = false
        settings.mediaAppVisibility = [:]
        settings.showQuickPeekOnTrackChange = false
        settings.persistMusicWidgetWhenPaused = false
        let fixedSettings = settings
        let callbacks = callbacks!
        let clock = clock!
        manager = MusicManager(
            mediaController: controller,
            spotifyScript: script,
            settingsProvider: { fixedSettings },
            settingsChanges: Empty().eraseToAnyPublisher(),
            now: { clock.now },
            scheduleOnMain: { callbacks.enqueue($0) }
        )
        XCTAssertTrue(RunningApps.shared.isRunning(Self.host), "The test host must count as a running media app")
    }

    override func tearDown() async throws {
        manager = nil
        clock = nil
        callbacks = nil
        script = nil
        controller = nil
    }

    // MARK: - Command routing

    func testNonSpotifySourceSendsEveryControlToSystemNowPlaying() async {
        deliver(track(Self.host, title: "Song", playing: true))
        XCTAssertEqual(manager.currentSourceKey, Self.host)

        await runAllControls()

        XCTAssertEqual(controller.commands, ["play", "pause", "next", "previous", "seek:42.0", "shuffle", "repeat"])
        XCTAssertEqual(script.commands, [])
    }

    func testSpotifyOwningNowPlayingIsControlledThroughSystemNowPlaying() async {
        deliver(track(Self.spotify, title: "Song", playing: true))
        XCTAssertEqual(manager.currentSourceKey, Self.spotify)

        await runAllControls()

        XCTAssertEqual(controller.commands, ["play", "pause", "next", "previous", "seek:42.0", "shuffle", "repeat"])
        XCTAssertEqual(script.commands, [])
    }

    func testControlFollowsNowPlayingAcrossHandOffs() async {
        deliver(track(Self.spotify, title: "Spotify song", playing: true))
        manager.selectSource(key: Self.spotify, userInitiated: true)

        deliver(track(Self.host, title: "Browser video", playing: true))
        XCTAssertEqual(manager.currentSourceKey, Self.host, "The pin ends with its source; the new owner is selected")
        XCTAssertFalse(manager.isSpotifySourceSelected)
        await runAllControls()
        XCTAssertEqual(controller.commands, ["play", "pause", "next", "previous", "seek:42.0", "shuffle", "repeat"])

        deliver(track(Self.spotify, title: "Spotify song", playing: true))
        XCTAssertEqual(manager.currentSourceKey, Self.spotify)
        await runAllControls()

        XCTAssertEqual(controller.commands.count, 14)
        XCTAssertEqual(script.commands, [], "Spotify is never scripted once a hand-off has been applied")
    }

    func testPausedSpotifyHandsOverToAnotherApp() async {
        deliver(track(Self.spotify, title: "Spotify song", playing: true))
        await manager.pause()
        deliver(track(Self.spotify, title: "Spotify song", playing: false, elapsed: 11))
        XCTAssertFalse(manager.isPlaying)

        deliver(track(Self.host, title: "Browser video", playing: true))

        XCTAssertEqual(manager.currentSourceKey, Self.host)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(manager.title, "Browser video")
        await manager.pause()
        XCTAssertEqual(controller.commands, ["pause", "pause"])
        XCTAssertEqual(script.commands, [])
    }

    func testSpotifyQuittingClearsTheSelection() async {
        deliver(track(Self.spotify, title: "Spotify song", playing: true))
        manager.selectSource(key: Self.spotify, userInitiated: true)

        clearNowPlaying()

        XCTAssertNil(manager.currentSourceKey)
        XCTAssertNil(manager.title)
        XCTAssertFalse(manager.isPlaying)
        await manager.play()
        XCTAssertEqual(controller.commands, ["play"], "With nothing selected, play goes to system Now Playing")
        XCTAssertEqual(script.commands, [])
    }

    // MARK: - Spotify between a hand-off and its callback
    //
    // The controller replaces its owner and reports it at once, but MusicManager applies
    // the report in a later main-actor task. A control used in between still finds Spotify
    // selected while it no longer owns Now Playing. This is the only state in which the
    // AppleScript path runs.

    func testSpotifyIsScriptedUntilAHandOffIsApplied() async {
        deliver(track(Self.spotify, title: "Spotify song", playing: false))
        controller.nowPlaying(track(Self.host, title: "Browser video", playing: false))
        XCTAssertEqual(manager.currentSourceKey, Self.spotify)

        await manager.play()
        await manager.pause()
        await manager.seek(to: 42)
        await manager.nextTrack()
        await manager.previousTrack()

        XCTAssertEqual(script.commands, ["resume", "pause", "seek:42.0"])
        XCTAssertEqual(controller.commands, ["next", "previous"], "Skipping was never scripted while signed out")

        callbacks.runAll()
        XCTAssertEqual(manager.currentSourceKey, Self.host)
        await manager.play()
        XCTAssertEqual(controller.commands.last, "play")
        XCTAssertEqual(script.commands.count, 3)
    }

    func testSpotifyIsScriptedUntilAClearIsApplied() async {
        deliver(track(Self.spotify, title: "Spotify song", playing: false))
        controller.clear()

        await manager.play()
        XCTAssertEqual(script.commands, ["resume"])

        callbacks.runAll()
        XCTAssertNil(manager.currentSourceKey)
        XCTAssertEqual(controller.commands, [])
    }

    func testShuffleAndRepeatStayLocalUntilAHandOffIsApplied() async {
        deliver(track(Self.spotify, title: "Spotify song", playing: false))
        controller.nowPlaying(track(Self.host, title: "Browser video", playing: false))

        await manager.toggleShuffle()
        await manager.cycleRepeatMode()

        XCTAssertEqual(controller.commands, [], "Never sent to the app that just took Now Playing")
        XCTAssertEqual(script.commands, [])
        XCTAssertTrue(manager.shuffleState, "The button keeps its own state as before")
        XCTAssertEqual(manager.repeatState, .context)
    }

    func testSpotifyThatIsNotRunningFallsBackToSystemNowPlaying() async {
        deliver(track(Self.spotify, title: "Spotify song", playing: false))
        controller.nowPlaying(track(Self.host, title: "Browser video", playing: false))
        script.isRunning = false

        await manager.play()
        await manager.pause()
        await manager.seek(to: 42)

        XCTAssertEqual(controller.commands, ["play", "pause", "seek:42.0"])
        XCTAssertEqual(script.commands, [])
    }

    func testFailedScriptIsNeitherRetriedNorRolledBack() async {
        deliver(track(Self.spotify, title: "Spotify song", playing: false))
        controller.nowPlaying(track(Self.host, title: "Browser video", playing: false))
        script.succeeds = false

        await manager.play()
        XCTAssertTrue(manager.isPlaying, "The optimistic state stays; the next report corrects it")
        await manager.seek(to: 42)
        XCTAssertEqual(manager.currentElapsedTime, 42, accuracy: 0.5)
        await manager.pause()
        XCTAssertFalse(manager.isPlaying)

        XCTAssertEqual(script.commands, ["resume", "seek:42.0", "pause"])
        XCTAssertEqual(controller.commands, [], "A failed script does not fall back to the other app")
    }

    // MARK: - Seek

    func testSeekIsClampedToTheTrack() async {
        deliver(track(Self.host, title: "Song", playing: false))
        XCTAssertEqual(manager.totalDuration, 200)

        await manager.seek(to: -5)
        await manager.seek(to: 500)
        await manager.seek(to: 42)
        await manager.seek(by: 5)
        await manager.seek(by: -100)
        await manager.seek(by: 500)

        XCTAssertEqual(controller.commands, ["seek:0.0", "seek:200.0", "seek:42.0", "seek:47.0", "seek:0.0", "seek:200.0"])
        XCTAssertEqual(manager.currentElapsedTime, 200)
    }

    func testSeekWithoutADurationIsOnlyKeptAboveZero() async {
        deliver(track(Self.host, title: "Live stream", playing: false, durationMicros: nil))
        XCTAssertEqual(manager.totalDuration, 0)

        await manager.seek(to: 500)
        await manager.seek(to: -5)

        XCTAssertEqual(controller.commands, ["seek:500.0", "seek:0.0"])
    }

    // MARK: - Play state

    func testPausedReportJustAfterSkippingDoesNotFlipThePlayButton() async {
        deliver(track(Self.host, title: "Song", playing: true))
        XCTAssertTrue(manager.isPlaying)

        await manager.nextTrack()
        clock.advance(by: 1.1)
        deliver(track(Self.host, title: "Next song", playing: false))
        XCTAssertTrue(manager.isPlaying, "A paused report inside the 1.2s hold after a skip is ignored")

        clock.advance(by: 0.2)
        deliver(track(Self.host, title: "Next song", playing: false, elapsed: 11))
        XCTAssertFalse(manager.isPlaying, "After the hold the same state is applied")
    }

    func testPlayAppliesTheFirstReportThatFollows() async {
        // play()/pause() start a hold and then immediately satisfy it, which ends it.
        // This was already so before the removal; the test pins the behavior so a
        // change to it is deliberate.
        deliver(track(Self.host, title: "Song", playing: false))

        await manager.play()
        XCTAssertTrue(manager.isPlaying)
        deliver(track(Self.host, title: "Song", playing: false, elapsed: 11))
        XCTAssertFalse(manager.isPlaying)
    }

    func testPlaybackRateAloneDecidesThePlayState() {
        deliver(track(Self.host, title: "Song", playing: nil, rate: 1))
        XCTAssertTrue(manager.isPlaying)

        deliver(track(Self.host, title: "Song", playing: nil, rate: 0))
        XCTAssertFalse(manager.isPlaying)
    }

    func testSpotifyIdleStateAcrossHandOffs() {
        deliver(track(Self.spotify, title: "Spotify song", playing: false))
        XCTAssertTrue(manager.isSpotifyPausedWithNoSystemMediaPlaying)

        deliver(track(Self.host, title: "Browser video", playing: true))
        XCTAssertFalse(manager.isSpotifyPausedWithNoSystemMediaPlaying, "Another app is playing")

        deliver(track(Self.host, title: "Browser video", playing: false))
        XCTAssertFalse(manager.isSpotifyPausedWithNoSystemMediaPlaying, "The paused app shown is not Spotify")

        deliver(track(Self.spotify, title: "Spotify song", playing: false))
        XCTAssertTrue(manager.isSpotifyPausedWithNoSystemMediaPlaying)

        deliver(track(Self.spotify, title: "Spotify song", playing: true))
        XCTAssertFalse(manager.isSpotifyPausedWithNoSystemMediaPlaying)

        clearNowPlaying()
        XCTAssertTrue(manager.isSpotifyPausedWithNoSystemMediaPlaying, "Spotify was the last app shown")
    }

    // MARK: - Source selection

    func testNowPlayingOwnerIsAlwaysTheSelectedSource() {
        deliver(track(Self.finder, title: "Paused", playing: false))
        XCTAssertEqual(manager.currentSourceKey, Self.finder)
        XCTAssertEqual(Array(manager.activeMediaSources.keys), [Self.finder])

        deliver(track(Self.host, title: "Playing", playing: true))
        XCTAssertEqual(manager.currentSourceKey, Self.host)
        XCTAssertEqual(Array(manager.activeMediaSources.keys), [Self.host], "One owner, so one source")
    }

    func testUserPinEndsWhenItsSourceLosesNowPlaying() {
        deliver(track(Self.host, title: "Playing", playing: true))
        manager.selectSource(key: Self.host, userInitiated: true)

        deliver(track(Self.finder, title: "Paused", playing: false))
        XCTAssertEqual(manager.currentSourceKey, Self.finder, "Even a paused new owner replaces a pinned source")

        deliver(track(Self.host, title: "Playing", playing: true))
        XCTAssertEqual(manager.currentSourceKey, Self.host)
    }

    // MARK: - Shuffle / repeat

    func testShuffleAndRepeatFollowNowPlaying() {
        deliver(track(Self.host, title: "Song", playing: true, shuffle: 3, repeat: 2))
        XCTAssertTrue(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .track)

        deliver(track(Self.host, title: "Song", playing: true, shuffle: 1, repeat: 3))
        XCTAssertFalse(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .context)

        deliver(track(Self.host, title: "Song", playing: true, shuffle: 1, repeat: 1))
        XCTAssertEqual(manager.repeatState, .off)

        deliver(track(Self.host, title: "Song", playing: true, shuffle: 2, repeat: nil))
        XCTAssertTrue(manager.shuffleState, "Album shuffle counts as on")
        XCTAssertEqual(manager.repeatState, .off, "An unreported mode leaves the state alone")
    }

    func testUnknownMediaRemoteModesLeaveTheStateAlone() {
        for mode in [nil, 0, 4, -1] {
            XCTAssertNil(MusicManager.shuffleState(fromMediaRemoteMode: mode), String(describing: mode))
            XCTAssertNil(MusicManager.repeatState(fromMediaRemoteMode: mode), String(describing: mode))
        }

        deliver(track(Self.host, title: "Song", playing: true, shuffle: 3, repeat: 2))
        deliver(track(Self.host, title: "Song", playing: true, elapsed: 11, shuffle: 0, repeat: 0))
        XCTAssertTrue(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .track)
    }

    func testReportedModesAreNotToggledLocally() async {
        deliver(track(Self.spotify, title: "Song", playing: true, shuffle: 1, repeat: 1))

        await manager.toggleShuffle()
        await manager.cycleRepeatMode()

        XCTAssertFalse(manager.shuffleState, "The next Now Playing report decides")
        XCTAssertEqual(manager.repeatState, .off)
        XCTAssertEqual(controller.commands, ["shuffle", "repeat"])
    }

    func testUnreportedSpotifyModesToggleLocally() async {
        deliver(track(Self.spotify, title: "Song", playing: true))

        await manager.toggleShuffle()
        await manager.cycleRepeatMode()
        await manager.cycleRepeatMode()

        XCTAssertTrue(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .track)
        XCTAssertEqual(controller.commands, ["shuffle", "repeat", "repeat"])
    }

    func testSwitchingSourceKeepsModesUntilASourceReportsThem() async {
        // As before the removal, switching source does not reset shuffle and repeat:
        // Spotify's locally toggled state is still right when it comes back.
        deliver(track(Self.spotify, title: "Spotify song", playing: true))
        await manager.toggleShuffle()
        await manager.cycleRepeatMode()

        deliver(track(Self.host, title: "Browser video", playing: true))
        XCTAssertEqual(manager.currentSourceKey, Self.host)
        XCTAssertTrue(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .context)

        deliver(track(Self.spotify, title: "Spotify song", playing: true))
        XCTAssertTrue(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .context)

        deliver(track(Self.finder, title: "Other", playing: true, shuffle: 1, repeat: 1))
        XCTAssertFalse(manager.shuffleState, "A source that reports its modes sets them")
        XCTAssertEqual(manager.repeatState, .off)
    }

    // MARK: - HUD app volume slider

    func testHUDSliderSetsTheShownAppsVolume() {
        var calls: [(Double, String)] = []
        let applied = AppVolumeSliderCommand.apply(level: 0.25, toAppWithBundleID: "com.example.player", ownBundleID: "own") {
            calls.append(($0, $1))
        }
        XCTAssertEqual(applied, 0.25)
        XCTAssertEqual(calls.map(\.0), [0.25])
        XCTAssertEqual(calls.map(\.1), ["com.example.player"])

        AppVolumeSliderCommand.apply(level: 1.4, toAppWithBundleID: "com.example.player", ownBundleID: "own") {
            calls.append(($0, $1))
        }
        XCTAssertEqual(calls.last?.0, 1.0)
    }

    func testHUDSliderLeavesAppsTheVolumeKeysSkip() {
        for bundleID in [nil, "", "com.spotify.client", "com.apple.Music", "own"] {
            var called = false
            let applied = AppVolumeSliderCommand.apply(level: 0.5, toAppWithBundleID: bundleID, ownBundleID: "own") { _, _ in
                called = true
            }
            XCTAssertNil(applied, String(describing: bundleID))
            XCTAssertFalse(called, String(describing: bundleID))
        }
    }

    // MARK: - Helpers

    private func runAllControls() async {
        await manager.play()
        await manager.pause()
        await manager.nextTrack()
        await manager.previousTrack()
        await manager.seek(to: 42)
        await manager.toggleShuffle()
        await manager.cycleRepeatMode()
    }

    /// The app takes (or updates) Now Playing and MusicManager applies the report.
    private func deliver(_ info: TrackInfo) {
        controller.nowPlaying(info)
        callbacks.runAll()
    }

    /// Now Playing goes empty, as when its owner quits, and MusicManager applies it.
    private func clearNowPlaying() {
        controller.clear()
        callbacks.runAll()
    }

    private func track(
        _ bundleID: String,
        title: String,
        playing: Bool?,
        rate: Float? = nil,
        elapsed: TimeInterval = 10,
        durationMicros: Int64? = 200_000_000,
        shuffle: Int? = nil,
        repeat repeatMode: Int? = nil
    ) -> TrackInfo {
        TrackInfo(payload: TrackInfo.Payload(
            bundleIdentifier: bundleID,
            title: title,
            artist: "Artist",
            isPlaying: playing,
            durationMicros: durationMicros,
            currentElapsedTime: elapsed,
            playbackRate: rate,
            repeatMode: repeatMode,
            shuffleMode: shuffle
        ))
    }
}

/// Follows `NativeMediaController`: a single owner keyed by its bundle ID, replaced whole;
/// after the replacement `onActiveClientsChanged` and then `onTrackInfoReceived` fire,
/// synchronously. Clearing empties it and reports `[:]` and `nil` in the same order.
@MainActor
private final class RecordingMediaController: SystemMediaControlling {
    var onActiveClientsChanged: (([String: TrackInfo]) -> Void)?
    var onListenerTerminated: (() -> Void)?
    var onDecodingError: ((String, String?) -> Void)?
    var onTrackInfoReceived: ((TrackInfo?) -> Void)?
    private(set) var activeClients: [String: TrackInfo] = [:]
    private(set) var commands: [String] = []

    func nowPlaying(_ track: TrackInfo) {
        let key = track.payload.bundleIdentifier ?? "unknown"
        activeClients = [key: track]
        onActiveClientsChanged?(activeClients)
        onTrackInfoReceived?(track)
    }

    func clear() {
        activeClients.removeAll()
        onActiveClientsChanged?([:])
        onTrackInfoReceived?(nil)
    }

    func startListening() {}
    func restartListeningIfNeeded() {}
    func play() { commands.append("play") }
    func pause() { commands.append("pause") }
    func nextTrack() { commands.append("next") }
    func previousTrack() { commands.append("previous") }
    func setTime(seconds: Double) { commands.append("seek:\(seconds)") }
    func toggleShuffle() { commands.append("shuffle") }
    func toggleRepeat() { commands.append("repeat") }
    func trimArtworkCache(keeping identity: String?) {}
}

@MainActor
private final class RecordingSpotifyScript: SpotifyPlaybackScripting {
    var isRunning = true
    var succeeds = true
    private(set) var commands: [String] = []

    func isAppRunning() -> Bool { isRunning }
    func resume() async -> Bool { commands.append("resume"); return succeeds }
    func pause() async -> Bool { commands.append("pause"); return succeeds }
    func seek(to seconds: TimeInterval) async -> Bool { commands.append("seek:\(seconds)"); return succeeds }
}

/// Holds the main-actor work MusicManager defers from controller callbacks until the
/// test runs it, in order.
private final class ManualMainQueue {
    private var jobs: [@MainActor () -> Void] = []

    func enqueue(_ job: @escaping @MainActor () -> Void) { jobs.append(job) }

    @MainActor
    func runAll() {
        while !jobs.isEmpty { jobs.removeFirst()() }
    }
}

private final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(by seconds: TimeInterval) { now.addTimeInterval(seconds) }
}
