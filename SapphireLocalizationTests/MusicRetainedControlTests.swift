import AppKit
import Combine
import XCTest
@testable import Sapphire

/// The basic music controls kept after the third-party integrations were removed:
/// command routing, play-state hold, source selection, shuffle/repeat state and the
/// HUD's app volume slider.
@MainActor
final class MusicRetainedControlTests: XCTestCase {
    private static let spotify = "com.spotify.client"
    private static let finder = "com.apple.finder"
    /// The test host is a running app, which the source filter requires.
    private static var host: String { Bundle.main.bundleIdentifier ?? "com.cshariq.sapphire" }

    private var controller: RecordingMediaController!
    private var script: RecordingSpotifyScript!
    private var manager: MusicManager!

    override func setUp() async throws {
        controller = RecordingMediaController()
        script = RecordingSpotifyScript()
        var settings = Settings()
        settings.mediaSource = .system
        settings.prioritizeMediaSource = false
        settings.mediaAppVisibility = [:]
        settings.showQuickPeekOnTrackChange = false
        let fixedSettings = settings
        manager = MusicManager(
            mediaController: controller,
            spotifyScript: script,
            settingsProvider: { fixedSettings },
            settingsChanges: Just(fixedSettings).eraseToAnyPublisher()
        )
        XCTAssertTrue(RunningApps.shared.isRunning(Self.host), "The test host must count as a running media app")
    }

    override func tearDown() async throws {
        manager = nil
        script = nil
        controller = nil
    }

    // MARK: - Command routing

    func testNonSpotifySourceSendsEveryControlToSystemNowPlaying() async {
        await deliver([Self.host: track(Self.host, title: "Song", playing: true)])
        XCTAssertEqual(manager.currentSourceKey, Self.host)

        await runAllControls()

        XCTAssertEqual(controller.commands, ["play", "pause", "next", "previous", "seek:42.0", "shuffle", "repeat"])
        XCTAssertEqual(script.commands, [])
    }

    func testSpotifyOwningNowPlayingIsControlledThroughSystemNowPlaying() async {
        await deliver([Self.spotify: track(Self.spotify, title: "Song", playing: true)])
        XCTAssertEqual(manager.currentSourceKey, Self.spotify)

        await runAllControls()

        XCTAssertEqual(controller.commands, ["play", "pause", "next", "previous", "seek:42.0", "shuffle", "repeat"])
        XCTAssertEqual(script.commands, [])
    }

    func testSelectedSpotifyIsScriptedWhenAnotherAppOwnsNowPlaying() async {
        await selectSpotifyWhileHostOwnsNowPlaying()

        await manager.play()
        await manager.pause()
        await manager.seek(to: 42)
        await manager.nextTrack()
        await manager.previousTrack()

        XCTAssertEqual(script.commands, ["resume", "pause", "seek:42.0"])
        XCTAssertEqual(controller.commands, ["next", "previous"], "Skipping was never scripted while signed out")
    }

    func testSelectedSpotifyNeverSendsShuffleOrRepeatToAnotherApp() async {
        await selectSpotifyWhileHostOwnsNowPlaying()

        await manager.toggleShuffle()
        await manager.cycleRepeatMode()

        XCTAssertEqual(controller.commands, [])
        XCTAssertEqual(script.commands, [])
        XCTAssertTrue(manager.shuffleState, "The button keeps its own state as before")
        XCTAssertEqual(manager.repeatState, .context)
    }

    func testSelectedSpotifyThatIsNotRunningFallsBackToSystemNowPlaying() async {
        await selectSpotifyWhileHostOwnsNowPlaying()
        script.isRunning = false

        await manager.play()
        await manager.pause()
        await manager.seek(to: 42)

        XCTAssertEqual(controller.commands, ["play", "pause", "seek:42.0"])
        XCTAssertEqual(script.commands, [])
    }

    // MARK: - Play state

    func testPausedReportJustAfterSkippingDoesNotFlipThePlayButton() async throws {
        let playing = track(Self.host, title: "Song", playing: true)
        let paused = track(Self.host, title: "Song", playing: false)
        await deliver([Self.host: playing])
        XCTAssertTrue(manager.isPlaying)

        await manager.nextTrack()
        await report(paused)
        XCTAssertTrue(manager.isPlaying, "A paused report inside the 1.2s hold after a skip is ignored")

        try await Task.sleep(for: .milliseconds(1300))
        await report(paused)
        XCTAssertFalse(manager.isPlaying, "After the hold the same report is applied")
    }

    func testPlayAppliesTheFirstReportThatFollows() async {
        // play()/pause() start a hold and then immediately satisfy it, which ends it.
        // This was already so before the removal; the test pins the behavior so a
        // change to it is deliberate.
        let paused = track(Self.host, title: "Song", playing: false)
        await deliver([Self.host: paused])

        await manager.play()
        XCTAssertTrue(manager.isPlaying)
        await report(paused)
        XCTAssertFalse(manager.isPlaying)
    }

    func testPlaybackRateAloneDecidesThePlayState() async {
        await deliver([Self.host: track(Self.host, title: "Song", playing: nil, rate: 1)])
        XCTAssertTrue(manager.isPlaying)

        await report(track(Self.host, title: "Song", playing: nil, rate: 0))
        XCTAssertFalse(manager.isPlaying)
    }

    func testSpotifyIsNotIdleWhileAnotherSourceIsPlaying() async {
        await deliver([
            Self.spotify: track(Self.spotify, title: "Paused", playing: false),
            Self.host: track(Self.host, title: "Playing", playing: true),
        ])
        manager.selectSource(key: Self.spotify, userInitiated: true)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertFalse(manager.isSpotifyPausedWithNoSystemMediaPlaying)

        await deliver([
            Self.spotify: track(Self.spotify, title: "Paused", playing: false),
            Self.host: track(Self.host, title: "Playing", playing: false),
        ])
        XCTAssertEqual(manager.currentSourceKey, Self.spotify)
        XCTAssertTrue(manager.isSpotifyPausedWithNoSystemMediaPlaying)
    }

    // MARK: - Source selection

    func testPlayingSourceWinsAndAUserPinHoldsAgainstIt() async {
        await deliver([
            Self.spotify: track(Self.spotify, title: "Paused", playing: false),
            Self.host: track(Self.host, title: "Playing", playing: true),
        ])
        XCTAssertEqual(manager.currentSourceKey, Self.host, "A playing source is preferred")

        manager.selectSource(key: Self.spotify, userInitiated: true)
        await deliver([
            Self.spotify: track(Self.spotify, title: "Paused", playing: false),
            Self.host: track(Self.host, title: "Next song", playing: true),
        ])
        XCTAssertEqual(manager.currentSourceKey, Self.spotify, "A source the user picked stays selected")

        await deliver([Self.host: track(Self.host, title: "Next song", playing: true)])
        XCTAssertEqual(manager.currentSourceKey, Self.host, "The pin ends when its source disappears")
    }

    func testPlayingSourceReplacesAPausedOneWithoutAPin() async {
        await deliver([Self.finder: track(Self.finder, title: "Paused", playing: false)])
        XCTAssertEqual(manager.currentSourceKey, Self.finder)

        await deliver([
            Self.finder: track(Self.finder, title: "Paused", playing: false),
            Self.host: track(Self.host, title: "Playing", playing: true),
        ])
        XCTAssertEqual(manager.currentSourceKey, Self.host)
    }

    // MARK: - Shuffle / repeat

    func testShuffleAndRepeatFollowNowPlaying() async {
        await deliver([Self.host: track(Self.host, title: "Song", playing: true, shuffle: 3, repeat: 2)])
        XCTAssertTrue(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .track)

        await report(track(Self.host, title: "Song", playing: true, shuffle: 1, repeat: 3))
        XCTAssertFalse(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .context)

        await report(track(Self.host, title: "Song", playing: true, shuffle: 1, repeat: 1))
        XCTAssertEqual(manager.repeatState, .off)

        await report(track(Self.host, title: "Song", playing: true, shuffle: 2, repeat: nil))
        XCTAssertTrue(manager.shuffleState, "Album shuffle counts as on")
        XCTAssertEqual(manager.repeatState, .off, "An unreported mode leaves the state alone")
    }

    func testReportedModesAreNotToggledLocally() async {
        await deliver([Self.spotify: track(Self.spotify, title: "Song", playing: true, shuffle: 1, repeat: 1)])

        await manager.toggleShuffle()
        await manager.cycleRepeatMode()

        XCTAssertFalse(manager.shuffleState, "The next Now Playing report decides")
        XCTAssertEqual(manager.repeatState, .off)
        XCTAssertEqual(controller.commands, ["shuffle", "repeat"])
    }

    func testUnreportedSpotifyModesToggleLocally() async {
        await deliver([Self.spotify: track(Self.spotify, title: "Song", playing: true)])

        await manager.toggleShuffle()
        await manager.cycleRepeatMode()
        await manager.cycleRepeatMode()

        XCTAssertTrue(manager.shuffleState)
        XCTAssertEqual(manager.repeatState, .track)
        XCTAssertEqual(controller.commands, ["shuffle", "repeat", "repeat"])
    }

    func testSwitchingSourceDropsTheOldSourcesModes() async {
        await deliver([Self.host: track(Self.host, title: "Song", playing: true, shuffle: 3, repeat: 2)])
        XCTAssertTrue(manager.shuffleState)

        await deliver([Self.finder: track(Self.finder, title: "Other", playing: true)])
        XCTAssertEqual(manager.currentSourceKey, Self.finder)
        XCTAssertFalse(manager.shuffleState)
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

    private func selectSpotifyWhileHostOwnsNowPlaying() async {
        await deliver([
            Self.spotify: track(Self.spotify, title: "Spotify song", playing: false),
            Self.host: track(Self.host, title: "Other song", playing: false),
        ])
        manager.selectSource(key: Self.spotify, userInitiated: true)
        controller.activeClients = [Self.host: track(Self.host, title: "Other song", playing: false)]
        XCTAssertEqual(manager.currentSourceKey, Self.spotify)
        XCTAssertTrue(manager.isSpotifySourceSelected)
    }

    private func deliver(_ clients: [String: TrackInfo]) async {
        controller.activeClients = clients
        controller.onActiveClientsChanged?(clients)
        await drainMainActor()
    }

    private func report(_ info: TrackInfo) async {
        controller.onTrackInfoReceived?(info)
        await drainMainActor()
    }

    /// The controller callbacks hop to the main actor in a new task.
    private func drainMainActor() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func track(
        _ bundleID: String,
        title: String,
        playing: Bool?,
        rate: Float? = nil,
        shuffle: Int? = nil,
        repeat repeatMode: Int? = nil
    ) -> TrackInfo {
        TrackInfo(payload: TrackInfo.Payload(
            bundleIdentifier: bundleID,
            title: title,
            artist: "Artist",
            isPlaying: playing,
            durationMicros: 200_000_000,
            currentElapsedTime: 10,
            playbackRate: rate,
            repeatMode: repeatMode,
            shuffleMode: shuffle
        ))
    }
}

@MainActor
private final class RecordingMediaController: SystemMediaControlling {
    var onActiveClientsChanged: (([String: TrackInfo]) -> Void)?
    var onListenerTerminated: (() -> Void)?
    var onDecodingError: ((String, String?) -> Void)?
    var onTrackInfoReceived: ((TrackInfo?) -> Void)?
    var activeClients: [String: TrackInfo] = [:]
    private(set) var commands: [String] = []

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
    private(set) var commands: [String] = []

    func isAppRunning() -> Bool { isRunning }
    func resume() async -> Bool { commands.append("resume"); return true }
    func pause() async -> Bool { commands.append("pause"); return true }
    func seek(to seconds: TimeInterval) async -> Bool { commands.append("seek:\(seconds)"); return true }
}
