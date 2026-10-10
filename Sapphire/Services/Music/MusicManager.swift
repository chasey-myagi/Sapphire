//
//  MusicManager.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2025-10-05
//

import Foundation
import AppKit
import Combine
import SwiftUI
import AudioToolbox
import ImageIO

/// The system Now Playing transport (mediaremote-adapter). Abstracted so the source
/// routing in `MusicManager` can be exercised without the adapter process.
@MainActor
protocol SystemMediaControlling: AnyObject {
    var onActiveClientsChanged: (([String: TrackInfo]) -> Void)? { get set }
    var onListenerTerminated: (() -> Void)? { get set }
    var onDecodingError: ((String, String?) -> Void)? { get set }
    var onTrackInfoReceived: ((TrackInfo?) -> Void)? { get set }
    /// The app that currently owns system Now Playing, keyed by its source key.
    var activeClients: [String: TrackInfo] { get }

    func startListening()
    func restartListeningIfNeeded()
    func play()
    func pause()
    func nextTrack()
    func previousTrack()
    func setTime(seconds: Double)
    func toggleShuffle()
    func toggleRepeat()
    func trimArtworkCache(keeping identity: String?)
}

extension NativeMediaController: SystemMediaControlling {}

@MainActor
class MusicManager: ObservableObject {
    static let shared = MusicManager()

    // MARK: - Specialized Sub-Managers
    lazy var browserAppleScript = BrowserAppleScriptManager.shared

    // MARK: - Published UI State
    let playbackTimePublisher = PassthroughSubject<(elapsed: TimeInterval, progress: Double), Never>()
    let volumePublisher = PassthroughSubject<Float, Never>()
    let trackDidChange = PassthroughSubject<Void, Never>()

    @Published var title: String?
    @Published var artist: String?
    @Published var album: String?
    @Published var artwork: NSImage?
    @Published var transientIcon: WaveformView.TransientIcon? = nil

    @Published var isPlaying: Bool = false {
        didSet(wasPlaying) {
            self.isWaveformAnimating = isPlaying
            if !isPlaying && wasPlaying {
                if title != nil { showTransientIcon(for: .paused) }
            } else if isPlaying && !wasPlaying {
                if transientIcon == .paused {
                    transientIconTimer?.invalidate()
                    transientIcon = nil
                }
            }
        }
    }

    func setDetailPlayerOpen(_ isOpen: Bool) async {
        guard isDetailPlayerOpen != isOpen else { return }
        isDetailPlayerOpen = isOpen
        print("[MusicManager:Timing] Detail Player open state changed to: \(isOpen)")
        if isOpen {
            publishPlaybackTime(force: true, includeProgressUI: true)
        }
        refreshArtworkColorExtractionIfNeeded()
    }

    func refreshPlayerUIAfterReturning() async {
        publishPlaybackTime(force: true, includeProgressUI: true)
        objectWillChange.send()
    }

    func setMusicLiveActivityActive(_ isActive: Bool) async {
        guard isMusicLiveActivityActive != isActive else { return }
        isMusicLiveActivityActive = isActive
        refreshArtworkColorExtractionIfNeeded()
    }

    @Published var totalDuration: TimeInterval = 0

    @Published var accentColor: Color = .white
    @Published var leftGradientColor: Color = .white
    @Published var rightGradientColor: Color = .white
    @Published var appIcon: NSImage?
    @Published var shouldShowLiveActivity: Bool = false
    @Published var shuffleState: Bool = false
    @Published var repeatState: RepeatMode = .off
    @Published var lastTrackChangeDate: Date?
    @Published var isHoveringAlbumArt: Bool = false
    @Published var showQuickPeek: Bool = false
    @Published var isWaveformAnimating: Bool = false
    @Published private(set) var lastKnownBundleID: String?
    @Published private(set) var currentTrackArtworkToken: String = ""

    @Published var activeMediaSources: [String: TrackInfo] = [:]
    @Published var currentSourceKey: String?
    private var sourcePinnedByUser = false
    private var lastPublishedSourceSignature: Int = 0
    private var lastExtractedArtworkToken: String?

    @Published private(set) var isDetailPlayerOpen: Bool = false
    @Published private(set) var isMusicLiveActivityActive: Bool = false
    private(set) var systemVolume: Float = 0.0

    private(set) var currentElapsedTime: TimeInterval = 0
    private(set) var playbackProgress: Double = 0.0

    // MARK: - Private Properties
    private let mediaController: SystemMediaControlling
    private let spotifyScript: SpotifyPlaybackScripting
    private let settingsProvider: () -> Settings
    private let settingsChanges: AnyPublisher<Settings, Never>
    private var settings: Settings { settingsProvider() }

    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var currentTrackDuration: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()
    private var quickPeekTimer: Timer?
    private var transientIconTimer: Timer?

    private var latestTrackPayload: TrackInfo.Payload?
    private var playbackTimingAnchor: PlaybackTimingAnchor?
    private var lastTrackIdentity: String?
    private var lastMediaFingerprint: String?
    private var artworkColorExtractionTask: Task<Void, Never>?
    private var playStateHoldUntil: Date = .distantPast
    private var playStateHoldPreferPlaying = true

    private var shouldExtractArtworkColors: Bool {
        isDetailPlayerOpen || isMusicLiveActivityActive
    }

    private convenience init() {
        self.init(
            mediaController: NativeMediaController(),
            spotifyScript: SpotifyAppleScriptManager.shared,
            settingsProvider: { SettingsModel.shared.settings },
            settingsChanges: SettingsModel.shared.$settings.eraseToAnyPublisher()
        )
    }

    init(
        mediaController: SystemMediaControlling,
        spotifyScript: SpotifyPlaybackScripting,
        settingsProvider: @escaping () -> Settings,
        settingsChanges: AnyPublisher<Settings, Never>
    ) {
        self.mediaController = mediaController
        self.spotifyScript = spotifyScript
        self.settingsProvider = settingsProvider
        self.settingsChanges = settingsChanges
        setupHandlers()
        setupNotificationObservers()
        setupVolumeListener()
        setupDerivedStatePublisher()
        setupSettingsObserver()
        mediaController.startListening()
    }

    private func applyPlayingState(_ playing: Bool) {
        let holding = Date() < playStateHoldUntil
        if holding {
            if playing == playStateHoldPreferPlaying {
                playStateHoldUntil = .distantPast
            } else {
                return
            }
        }
        if isPlaying != playing {
            isPlaying = playing
            freezeOrResumeTimingAnchor(playing: playing)
        } else {
            syncTimingAnchorRate(playing: playing)
        }
    }

    private func freezeOrResumeTimingAnchor(playing: Bool) {
        let now = Date()
        let elapsed = playbackTimingAnchor?.elapsed(at: now) ?? currentElapsedTime
        playbackTimingAnchor = PlaybackTimingAnchor(
            elapsedAtSample: max(0, elapsed),
            sampleEpochTime: now.timeIntervalSince1970,
            rate: playing ? 1.0 : 0.0
        )
        publishPlaybackTime(force: true, includeProgressUI: true)
    }

    private func syncTimingAnchorRate(playing: Bool) {
        guard let anchor = playbackTimingAnchor else {
            freezeOrResumeTimingAnchor(playing: playing)
            return
        }
        let desiredRate = playing ? 1.0 : 0.0
        guard abs(anchor.rate - desiredRate) > 0.01 else { return }
        freezeOrResumeTimingAnchor(playing: playing)
    }

    private func beginPlayStateHold(preferPlaying: Bool, duration: TimeInterval = 1.0) {
        playStateHoldPreferPlaying = preferPlaying
        playStateHoldUntil = Date().addingTimeInterval(duration)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        quickPeekTimer?.invalidate()
        transientIconTimer?.invalidate()
        if let volumeListener {
            Self.removeVolumeListener(volumeListener)
        }
    }

    // MARK: - Core Playback Actions (system Now Playing)

    func play() async {
        beginPlayStateHold(preferPlaying: true, duration: 1.2)
        applyPlayingState(true)

        if shouldScriptSpotify {
            _ = await spotifyScript.resume()
            return
        }
        mediaController.play()
    }

    func pause() async {
        beginPlayStateHold(preferPlaying: false, duration: 1.2)
        applyPlayingState(false)

        if shouldScriptSpotify {
            _ = await spotifyScript.pause()
            return
        }
        mediaController.pause()
    }

    func nextTrack() async {
        beginPlayStateHold(preferPlaying: true, duration: 1.2)
        mediaController.nextTrack()
    }

    func previousTrack() async {
        beginPlayStateHold(preferPlaying: true, duration: 1.2)
        mediaController.previousTrack()
    }

    func seek(to seconds: Double) async {
        let clamped = max(0.0, totalDuration > 0 ? min(seconds, totalDuration) : seconds)

        if shouldScriptSpotify {
            _ = await spotifyScript.seek(to: clamped)
            applyOptimisticSeek(to: clamped)
            return
        }
        mediaController.setTime(seconds: clamped)
        applyOptimisticSeek(to: clamped)
    }

    func seek(by seconds: TimeInterval) async {
        let newTime = max(0.0, min(currentElapsedTime + seconds, max(totalDuration, currentElapsedTime + seconds)))
        await seek(to: newTime)
    }

    func toggleShuffle() async {
        guard isSpotifySourceSelected else {
            mediaController.toggleShuffle()
            return
        }
        // Spotify keeps the button's own state, as before, unless Now Playing reports
        // its shuffle mode. A command is sent only while Spotify owns Now Playing, so
        // it never reaches another app.
        guard isSpotifySystemNowPlaying else {
            shuffleState.toggle()
            return
        }
        mediaController.toggleShuffle()
        if Self.shuffleState(fromMediaRemoteMode: latestTrackPayload?.shuffleMode) == nil {
            shuffleState.toggle()
        }
    }

    func cycleRepeatMode() async {
        guard isSpotifySourceSelected else {
            mediaController.toggleRepeat()
            return
        }
        guard isSpotifySystemNowPlaying else {
            repeatState = repeatState.next()
            return
        }
        mediaController.toggleRepeat()
        if Self.repeatState(fromMediaRemoteMode: latestTrackPayload?.repeatMode) == nil {
            repeatState = repeatState.next()
        }
    }

    // MARK: - Shuffle / repeat from Now Playing

    /// `kMRMediaRemoteNowPlayingInfoShuffleMode`: 1 off, 2 albums, 3 tracks; 0 or absent is unknown.
    static func shuffleState(fromMediaRemoteMode mode: Int?) -> Bool? {
        switch mode {
        case 1: return false
        case 2, 3: return true
        default: return nil
        }
    }

    /// `kMRMediaRemoteNowPlayingInfoRepeatMode`: 1 off, 2 one, 3 all; 0 or absent is unknown.
    static func repeatState(fromMediaRemoteMode mode: Int?) -> RepeatMode? {
        switch mode {
        case 1: return .off
        case 2: return .track
        case 3: return .context
        default: return nil
        }
    }

    private func applyTransportModes(from payload: TrackInfo.Payload) {
        if let shuffle = Self.shuffleState(fromMediaRemoteMode: payload.shuffleMode), shuffleState != shuffle {
            shuffleState = shuffle
        }
        if let repeatMode = Self.repeatState(fromMediaRemoteMode: payload.repeatMode), repeatState != repeatMode {
            repeatState = repeatMode
        }
    }

    // MARK: - Source helpers

    /// The Spotify desktop app reports through system Now Playing like any other
    /// player; these bundle-ID rules only keep the existing source ordering.
    private static let spotifyBundlePrefix = "com.spotify.client"

    private var isSpotifyDisplayedInUI: Bool {
        if currentSourceKey?.hasPrefix(Self.spotifyBundlePrefix) == true { return true }
        if currentSourceKey == nil, lastKnownBundleID == Self.spotifyBundlePrefix { return true }
        return false
    }

    var isSpotifySourceSelected: Bool {
        currentSourceKey.map(isSpotifySourceKey) ?? false
    }

    /// Whether Spotify owns system Now Playing, i.e. MediaRemote commands reach it.
    private var isSpotifySystemNowPlaying: Bool {
        mediaController.activeClients.keys.contains(where: isSpotifySourceKey)
    }

    /// Spotify is selected but another app owns Now Playing: play, pause and seek must be
    /// addressed to Spotify directly or they would control that other app.
    private var shouldScriptSpotify: Bool {
        isSpotifySourceSelected && !isSpotifySystemNowPlaying && spotifyScript.isAppRunning()
    }

    var isSpotifySourceActive: Bool {
        isSpotifyDisplayedInUI && lastKnownBundleID != "com.apple.Music"
    }

    var isSpotifyPausedWithNoSystemMediaPlaying: Bool {
        guard isSpotifySourceActive else { return false }
        guard !isPlaying else { return false }
        return !activeMediaSources.values.contains {
            resolvedIsPlaying(from: $0.payload) == true
        }
    }

    private func isSpotifySourceKey(_ key: String) -> Bool {
        key.hasPrefix(Self.spotifyBundlePrefix)
    }

    private func isAppleMusicSourceKey(_ key: String) -> Bool {
        key.hasPrefix("com.apple.Music")
    }

    private func bundleID(fromSourceKey key: String) -> String? {
        if key.contains("."), !key.contains(":") {
            return key
        }
        return key.split(separator: ":").first.map(String.init)
    }

    private func isSourceVisible(_ key: String) -> Bool {
        settings.isMediaAppVisible(bundleID: bundleID(fromSourceKey: key))
    }

    private func isSystemSourceAlive(key: String, track: TrackInfo?) -> Bool {
        guard !isSpotifySourceKey(key) else { return false }
        guard isSourceVisible(key) else { return false }

        guard let bundle = bundleID(fromSourceKey: key), !bundle.isEmpty else { return false }

        if !RunningApps.shared.isRunning(bundle) {
            let matchesHelper = RunningApps.shared.containsBundleID { appBundle in
                MediaApplicationIdentity.canonicalBundleID(appBundle) == bundle
            }
            guard matchesHelper else { return false }
        }

        guard let payload = track?.payload else { return false }
        return !payload.title.isBlank
    }

    private func mergedVisibleSources(_ clients: [String: TrackInfo]) -> [String: TrackInfo] {
        var merged: [String: TrackInfo] = [:]

        for (key, track) in clients {
            guard isSourceVisible(key) else { continue }
            if isSystemSourceAlive(key: key, track: track) || isSpotifySourceKey(key) {
                merged[key] = track
            }
        }

        return merged
    }

    private func sourceSignature(for sources: [String: TrackInfo]) -> Int {
        var combined = 0
        for (key, track) in sources {
            var hasher = Hasher()
            hasher.combine(key)
            hasher.combine(track.payload.title)
            hasher.combine(track.payload.artist)
            hasher.combine(track.payload.album)
            hasher.combine(resolvedIsPlaying(from: track.payload))
            combined ^= hasher.finalize()
        }
        return combined
    }

    private func publishMergedSources(_ merged: [String: TrackInfo], reselect: Bool) {
        let signature = sourceSignature(for: merged)
        let keysChanged = merged.count != activeMediaSources.count
            || merged.keys.contains { activeMediaSources[$0] == nil }
        if signature != lastPublishedSourceSignature || keysChanged {
            lastPublishedSourceSignature = signature
            activeMediaSources = merged
            if reselect {
                evaluateAutoSourceSelection(in: merged)
            }
        } else if merged != activeMediaSources {
            activeMediaSources = merged
        }
    }

    private func preferredSourceKey(in sources: [String: TrackInfo]) -> String? {
        guard !sources.isEmpty else { return nil }

        let localPlayingKeys = sources.compactMap { key, track -> String? in
            guard isSystemSourceAlive(key: key, track: track),
                  resolvedIsPlaying(from: track.payload) == true else { return nil }
            return key
        }
        if !localPlayingKeys.isEmpty,
           !sourcePinnedByUser {
            return preferredSourceKey(restrictedTo: localPlayingKeys)
        }

        if sourcePinnedByUser,
           let current = currentSourceKey,
           sources[current] != nil {
            return current
        }

        let playingKeys = sources.compactMap { resolvedIsPlaying(from: $0.value.payload) == true ? $0.key : nil }
        let pool = (playingKeys.isEmpty ? Array(sources.keys) : playingKeys).sorted()

        return preferredSourceKey(restrictedTo: pool)
            ?? currentSourceKey.flatMap { sources[$0] == nil ? nil : $0 }
            ?? sources.keys.min()
    }

    private func preferredSourceKey(restrictedTo pool: [String]) -> String? {
        let preferredKey: String?
        switch settings.mediaSource {
        case .system:
            preferredKey = pool.first(where: { !isSpotifySourceKey($0) })
                ?? pool.first(where: isSpotifySourceKey)
        case .spotify:
            preferredKey = pool.first(where: isSpotifySourceKey)
                ?? pool.first(where: { !isSpotifySourceKey($0) })
        case .appleMusic:
            preferredKey = pool.first(where: isAppleMusicSourceKey)
                ?? pool.first(where: { !isSpotifySourceKey($0) })
                ?? pool.first(where: isSpotifySourceKey)
        }
        return preferredKey
    }

    private func evaluateAutoSourceSelection(in sources: [String: TrackInfo]) {
        if sourcePinnedByUser,
           let current = currentSourceKey,
           sources[current] != nil {
            return
        }

        if sourcePinnedByUser {
            sourcePinnedByUser = false
        }

        guard let preferred = preferredSourceKey(in: sources) else {
            if currentSourceKey != nil || title != nil {
                clearPlayerState()
            }
            return
        }

        if preferred != currentSourceKey {
            selectSource(key: preferred)
        }
    }

    // MARK: - Multi-Source State Management

    private var appURLCache: [String: URL?] = [:]
    private var appIconCache: [String: NSImage] = [:]

    private func appURL(for bundleID: String) -> URL? {
        if let cached = appURLCache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        appURLCache[bundleID] = url
        return url
    }

    private func cachedAppIcon(for bundleID: String) -> NSImage? {
        if let cached = appIconCache[bundleID] { return cached }
        guard let url = appURL(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIconCache[bundleID] = icon
        return icon
    }

    func appName(for bundleID: String?) -> String {
        guard let bundleID = bundleID else { return String(localized: "Unknown") }
        if let url = appURL(for: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.components(separatedBy: ".").last?.capitalized ?? bundleID
    }

    func selectSource(key: String, userInitiated: Bool = false, payload: TrackInfo.Payload? = nil) {
        if userInitiated {
            sourcePinnedByUser = true
        }
        let switching = key != currentSourceKey
        let wasSpotify = currentSourceKey.map(isSpotifySourceKey) ?? false
        let isNowSpotify = isSpotifySourceKey(key)
        currentSourceKey = key

        if switching {
            if !(wasSpotify && isNowSpotify) {
                lastTrackIdentity = nil
                lastMediaFingerprint = nil
                shuffleState = false
                repeatState = .off
                currentTrackArtworkToken = "source-switch-\(key)-\(UUID().uuidString)"
                if !isNowSpotify {
                    if let bundle = key.split(separator: ":").first.map(String.init) {
                        lastKnownBundleID = MediaApplicationIdentity.canonicalBundleID(bundle) ?? bundle
                        fetchAppIcon(for: lastKnownBundleID ?? bundle)
                    }
                }
            } else {
                currentTrackArtworkToken = "source-switch-spotify-\(UUID().uuidString)"
            }
        }

        let resolvedPayload = payload ?? activeMediaSources[key]?.payload
        if let resolvedPayload {
            applyTrackPayload(resolvedPayload, sourceKey: key)
            publishPlaybackTime(force: true, includeProgressUI: true)
        }
    }

    private func setupHandlers() {
        mediaController.onActiveClientsChanged = { [weak self] clients in
            Task { @MainActor in
                guard let self = self else { return }
                let mergedClients = self.mergedVisibleSources(clients)
                self.publishMergedSources(mergedClients, reselect: true)

                guard let key = self.currentSourceKey else { return }
                guard let track = mergedClients[key] else {
                    self.evaluateAutoSourceSelection(in: mergedClients)
                    return
                }

                if self.hasMediaChanged(track.payload) {
                    self.applyTrackPayload(track.payload, sourceKey: key)
                } else if let payloadArtwork = track.payload.artwork, payloadArtwork !== self.artwork {
                    self.applyTrackPayload(track.payload, sourceKey: key)
                } else {
                    self.applyPlaybackRefresh(track.payload)
                }
            }
        }

        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            Task { @MainActor in
                guard let self = self, let track = trackInfo else { return }
                let bundle = MediaApplicationIdentity.canonicalBundleID(track.payload.bundleIdentifier) ?? track.payload.bundleIdentifier ?? "unknown"
                guard self.settings.isMediaAppVisible(bundleID: bundle) else { return }
                let newKey = bundle

                guard self.currentSourceKey == newKey else { return }

                if self.hasMediaChanged(track.payload) {
                    self.applyTrackPayload(track.payload, sourceKey: newKey)
                } else {
                    self.applyPlaybackRefresh(track.payload)
                    if let payloadArtwork = track.payload.artwork, payloadArtwork !== self.artwork {
                        self.applyTrackPayload(track.payload, sourceKey: newKey)
                    }
                }
            }
        }

        mediaController.onListenerTerminated = { [weak self] in
            print("[MusicManager] Native media stream lost. Restarting.")
            self?.mediaController.restartListeningIfNeeded()
        }
        mediaController.onDecodingError = { error, _ in print("[MusicManager] Error decoding system media: \(error)") }
    }

    private func refreshVisibleSources() {
        let merged = mergedVisibleSources(mediaController.activeClients)
        publishMergedSources(merged, reselect: false)
    }

    private func applyTrackPayload(_ payload: TrackInfo.Payload, sourceKey: String) {
        if let current = currentSourceKey, current != sourceKey { return }
        self.latestTrackPayload = payload

        guard let rawTitle = payload.title, !rawTitle.isEmpty else {
            applyPlaybackRefresh(payload)
            if self.title == nil { self.clearPlayerState() }
            return
        }

        let sourceBundleID = MediaApplicationIdentity.canonicalBundleID(payload.bundleIdentifier) ?? "N/A"
        let isSpotify = isSpotifySourceKey(sourceKey) || sourceBundleID == Self.spotifyBundlePrefix
        let switchingAwayFromSpotify = lastKnownBundleID == Self.spotifyBundlePrefix && !isSpotify

        if sourceBundleID != self.lastKnownBundleID {
            self.lastKnownBundleID = sourceBundleID
            self.fetchAppIcon(for: sourceBundleID)
        }

        let trackIdentity = self.trackIdentity(for: payload)
        let hasTrackChanged = hasMediaChanged(payload) || switchingAwayFromSpotify

        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String? = trimmedTitle.isEmpty ? rawTitle : trimmedTitle
        let resolvedArtist = payload.artist.trimmedOrNil
        let resolvedAlbum = payload.album.trimmedOrNil

        if self.title != resolvedTitle { self.title = resolvedTitle }
        if self.artist != resolvedArtist { self.artist = resolvedArtist }
        if self.album != resolvedAlbum { self.album = resolvedAlbum }

        if hasTrackChanged {
            self.lastTrackIdentity = trackIdentity
            let fingerprint = mediaFingerprint(for: payload)
            self.lastMediaFingerprint = fingerprint.isEmpty ? nil : fingerprint
            self.currentTrackArtworkToken = trackIdentity
            self.triggerQuickPeek()
            self.lastTrackChangeDate = Date()
            self.trackDidChange.send()
        }

        if let newArtwork = payload.artwork {
            self.applyArtwork(newArtwork, trackIdentity: trackIdentity)
        } else if switchingAwayFromSpotify {
            self.artwork = nil
        }

        if let newIsPlaying = resolvedIsPlaying(from: payload) {
            applyPlayingState(newIsPlaying)
        }
        applyTransportModes(from: payload)

        let newDuration = TimeInterval(payload.durationMicros ?? 0) / 1_000_000
        if abs(self.totalDuration - newDuration) > 0.5 {
            self.totalDuration = newDuration
        }
        self.currentTrackDuration = newDuration

        syncPlaybackTiming(from: payload, trackChanged: hasTrackChanged)
    }

    private func applyPlaybackRefresh(_ payload: TrackInfo.Payload) {
        latestTrackPayload = payload

        if let newIsPlaying = resolvedIsPlaying(from: payload) {
            applyPlayingState(newIsPlaying)
        }
        applyTransportModes(from: payload)

        let duration = TimeInterval(payload.durationMicros ?? 0) / 1_000_000
        if duration > 0, abs(duration - totalDuration) > 0.5 {
            currentTrackDuration = duration
            totalDuration = duration
        }

        syncPlaybackTiming(from: payload, trackChanged: false, publishImmediately: true)
    }

    private func resolvedIsPlaying(from payload: TrackInfo.Payload) -> Bool? {
        if let isPlaying = payload.isPlaying { return isPlaying }
        if let rate = payload.playbackRate { return rate != 0 }
        return nil
    }

    // MARK: - Logic & Helpers

    func sourceAppIcon(for key: String) -> NSImage {
        let bundleID: String?
        if let track = activeMediaSources[key] {
            bundleID = MediaApplicationIdentity.canonicalBundleID(track.payload.bundleIdentifier)
        } else if isSpotifySourceKey(key) {
            bundleID = Self.spotifyBundlePrefix
        } else {
            bundleID = nil
        }
        if let bundleID, let icon = cachedAppIcon(for: bundleID) { return icon }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    private func syncPlaybackTiming(from payload: TrackInfo.Payload, trackChanged: Bool, publishImmediately: Bool = true) {
        let isPlayingNow = payload.isPlaying ?? isPlaying
        guard let incomingAnchor = payload.playbackTimingAnchor(isPlayingNow: isPlayingNow) else { return }

        playbackTimingAnchor = incomingAnchor

        publishPlaybackTime(
            force: trackChanged || publishImmediately,
            includeProgressUI: isDetailPlayerOpen
        )
    }

    private func applyOptimisticSeek(to seconds: TimeInterval) {
        let clamped = totalDuration > 0 ? max(0, min(totalDuration, seconds)) : max(0, seconds)
        let reported = Double(latestTrackPayload?.playbackRate ?? 1.0)
        let rate = isPlaying ? (reported > 0 ? reported : 1.0) : 0
        playbackTimingAnchor = PlaybackTimingAnchor(
            elapsedAtSample: clamped,
            sampleEpochTime: Date().timeIntervalSince1970,
            rate: rate
        )
        publishPlaybackTime(force: true)
    }

    private func publishPlaybackTime(force: Bool = false, includeProgressUI: Bool? = nil) {
        let exactTime: TimeInterval

        if let anchor = playbackTimingAnchor {
            exactTime = anchor.elapsed(at: Date())
        } else if let payload = latestTrackPayload {
            exactTime = payload.interpolatedElapsedTime(at: Date())
        } else {
            return
        }

        let duration = totalDuration
        let clampedElapsed = duration > 0 ? max(0.0, min(duration, exactTime)) : max(0.0, exactTime)
        let progress = duration > 0 ? max(0.0, min(1.0, clampedElapsed / duration)) : 0.0

        let publishesProgress = includeProgressUI ?? (isDetailPlayerOpen || isMusicLiveActivityActive)

        if !force && !publishesProgress {
            return
        }

        let elapsedThreshold = publishesProgress ? 0.05 : 1.0
        let elapsedDelta = abs(clampedElapsed - currentElapsedTime)

        if !force && elapsedDelta < elapsedThreshold {
            return
        }

        currentElapsedTime = clampedElapsed

        if publishesProgress {
            if abs(playbackProgress - progress) > 0.001 || force {
                playbackProgress = progress
            }
            playbackTimePublisher.send((elapsed: clampedElapsed, progress: progress))
        }
    }

    private func clearPlayerState() {
        self.latestTrackPayload = nil
        self.currentSourceKey = nil
        self.sourcePinnedByUser = false
        playbackTimingAnchor = nil
        lastTrackIdentity = nil
        lastMediaFingerprint = nil
        currentTrackArtworkToken = ""
        self.isPlaying = false; self.totalDuration = 0; self.currentElapsedTime = 0
        if !settings.persistMusicWidgetWhenPaused {
            self.title = nil; self.artist = nil; self.album = nil; self.artwork = nil
        }
    }

    func elapsedTime(at date: Date = Date()) -> TimeInterval {
        let exact: TimeInterval
        if let anchor = playbackTimingAnchor {
            exact = anchor.elapsed(at: date)
        } else if let payload = latestTrackPayload {
            exact = payload.interpolatedElapsedTime(at: date)
        } else {
            return currentElapsedTime
        }
        return totalDuration > 0 ? max(0.0, min(totalDuration, exact)) : max(0.0, exact)
    }

    func progress(at date: Date = Date()) -> Double {
        guard totalDuration > 0 else { return 0 }
        return max(0.0, min(1.0, elapsedTime(at: date) / totalDuration))
    }

    func trimExpandedUIMemory() {
        mediaController.trimArtworkCache(keeping: lastTrackIdentity)
        appIcon = nil
    }

    private func hasMediaChanged(_ payload: TrackInfo.Payload) -> Bool {
        let fingerprint = mediaFingerprint(for: payload)
        if !fingerprint.isEmpty {
            return fingerprint != (lastMediaFingerprint ?? "")
        }

        let incomingIdentity = trackIdentity(for: payload)
        if incomingIdentity == "unknown" { return false }
        return incomingIdentity != (lastTrackIdentity ?? "")
    }

    private func mediaFingerprint(for payload: TrackInfo.Payload) -> String {
        Self.mediaFingerprint(title: payload.title, artist: payload.artist)
    }

    private static func mediaFingerprint(title: String?, artist: String?) -> String {
        switch (title.trimmedOrNil, artist.trimmedOrNil) {
        case let (title?, artist?): return "\(title)|\(artist)".lowercased()
        case let (title?, nil): return title.lowercased()
        case let (nil, artist?): return artist.lowercased()
        case (nil, nil): return ""
        }
    }

    private func trackIdentity(for payload: TrackInfo.Payload) -> String {
        if let id = payload.contentItemIdentifier, !id.isEmpty { return "cid:\(id)" }
        if let id = payload.uniqueIdentifier, !id.isEmpty { return "uid:\(id)" }
        let fingerprint = mediaFingerprint(for: payload)
        return fingerprint.isEmpty ? "unknown" : "fp:\(fingerprint)"
    }

    private func applyArtwork(_ displayArtwork: NSImage, trackIdentity: String? = nil) {
        if let trackIdentity, let last = lastTrackIdentity, trackIdentity != last { return }

        if self.artwork === displayArtwork { return }

        self.artwork = displayArtwork
        refreshArtworkColorExtractionIfNeeded()
    }

    private func refreshArtworkColorExtractionIfNeeded() {
        artworkColorExtractionTask?.cancel()
        guard shouldExtractArtworkColors else { return }

        let currentToken = "\(currentTrackArtworkToken)-\(artwork?.hashValue ?? 0)"
        if lastExtractedArtworkToken == currentToken { return }
        lastExtractedArtworkToken = currentToken

        artworkColorExtractionTask = Task { @MainActor in
            guard !Task.isCancelled, self.shouldExtractArtworkColors else { return }

            guard let artwork = artwork else { return }
            if let edgeColors = artwork.getEdgeColors() {
                let accent = edgeColors.accent.ensuringMinimumBrightness(0.52)
                self.accentColor = accent
                self.leftGradientColor = edgeColors.left.ensuringMinimumBrightness(0.42)
                self.rightGradientColor = edgeColors.right.ensuringMinimumBrightness(0.42)
            } else {
                self.resetColorsToDefault()
            }
        }
    }

    func openInSourceApp() {
        guard let bundleId = lastKnownBundleID else { return }
        if bundleId == "com.apple.Music" {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.Music" }?
                .activate()
            return
        }
        if ["com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.apple.Safari"].contains(bundleId) {
            guard let trackTitle = self.title else {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { NSWorkspace.shared.open(appURL) }
                return
            }
            browserAppleScript.focusTab(for: bundleId, with: trackTitle); return
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { NSWorkspace.shared.open(appURL) }
    }

    private func setupDerivedStatePublisher() {
        $title
            .map { $0?.isEmpty == false }
            .removeDuplicates()
            .assign(to: &$shouldShowLiveActivity)
    }

    private func setupNotificationObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleAppTermination(notification:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func handleAppTermination(notification: NSNotification) {
        guard let tApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let bID = tApp.bundleIdentifier else { return }
        Task { @MainActor in
            let normalized = MediaApplicationIdentity.canonicalBundleID(bID) ?? bID
            let prefixes = Set([bID, normalized])
            let keysToRemove = Set(
                self.activeMediaSources.keys.filter { key in
                    prefixes.contains(where: { key.hasPrefix($0) })
                }
            )
            guard !keysToRemove.isEmpty else { return }
            for key in keysToRemove {
                self.activeMediaSources.removeValue(forKey: key)
            }
            self.lastPublishedSourceSignature = 0
            if let current = self.currentSourceKey, keysToRemove.contains(current) {
                self.sourcePinnedByUser = false
                self.evaluateAutoSourceSelection(in: self.activeMediaSources)
            }
        }
    }

    nonisolated private static var volumeScalarAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func setupVolumeListener() {
        self.systemVolume = SystemControl.getVolume()
        guard let deviceID = Self.defaultOutputDeviceID() else { return }
        var address = Self.volumeScalarAddress
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            let volume = SystemControl.getVolume()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.systemVolume = volume
                self.volumePublisher.send(volume)
            }
        }
        self.volumeListener = listener
        AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, listener)
    }

    nonisolated private static func removeVolumeListener(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        var address = volumeScalarAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, listener)
    }

    nonisolated private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var dID: AudioDeviceID = kAudioObjectUnknown, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dID) == noErr ? dID : nil
    }

    private func fetchAppIcon(for bundleIdentifier: String?) {
        self.appIcon = bundleIdentifier.flatMap { cachedAppIcon(for: $0) }
    }

    private func resetColorsToDefault() {
        let def = Color(red: 0.53, green: 0.73, blue: 0.88)
        self.accentColor = def; self.leftGradientColor = def; self.rightGradientColor = def.opacity(0.7)
    }

    private func setupSettingsObserver() {
        settingsChanges
            .map { ($0.mediaAppVisibility, $0.mediaSource, $0.prioritizeMediaSource) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVisibleSources()
            }
            .store(in: &cancellables)
    }

    func showTransientIcon(for icon: WaveformView.TransientIcon, duration: TimeInterval = 2.0) {
        transientIconTimer?.invalidate()
        transientIcon = icon
        transientIconTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.transientIcon == icon else { return }
                self.transientIcon = nil
            }
        }
    }

    private func triggerQuickPeek() {
        guard settings.showQuickPeekOnTrackChange else { return }
        quickPeekTimer?.invalidate()
        self.showQuickPeek = true
        quickPeekTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showQuickPeek = false }
        }
    }
}

private extension Optional where Wrapped == String {
    var trimmedOrNil: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var isBlank: Bool { trimmedOrNil == nil }
}
