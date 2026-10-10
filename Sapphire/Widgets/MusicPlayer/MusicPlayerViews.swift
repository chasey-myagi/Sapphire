//
//  MusicPlayerViews.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-08-21

import SwiftUI
import AppKit
import Combine
import QuartzCore

// MARK: - Consolidated from MusicPlayerView.swift

struct PlayerProgressView: View {
    @EnvironmentObject var musicManager: MusicManager
    @State private var isSeeking = false
    @State private var seekProgress: Double = 0.0

    var lightStyle: Bool = false

    private var timeColor: Color {
        lightStyle ? Color.white.opacity(0.68) : Color.secondary
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: musicManager.isPlaying && !isSeeking ? 0.2 : 60)) { context in
            let liveElapsed = isSeeking
                ? seekProgress * musicManager.totalDuration
                : musicManager.elapsedTime(at: context.date)
            let liveProgress = isSeeking
                ? seekProgress
                : musicManager.progress(at: context.date)

            HStack(alignment: .center, spacing: 8) {
                Text(liveElapsed.asMinuteSecondClock)
                    .font(.system(size: lightStyle ? 11 : 10, weight: .medium, design: .monospaced))
                    .foregroundColor(timeColor)
                    .contentTransition(.numericText())

                InteractiveProgressBar(
                    value: Binding(
                        get: { liveProgress },
                        set: { seekProgress = $0 }
                    ),
                    gradient: Gradient(colors: lightStyle
                        ? [.white, .white.opacity(0.75)]
                        : [musicManager.leftGradientColor, musicManager.rightGradientColor]),
                    onSeek: { newProgress in
                        isSeeking = false
                        let seekTime = newProgress * musicManager.totalDuration
                        if seekTime.isFinite && musicManager.totalDuration > 0 {
                            Task { await musicManager.seek(to: seekTime) }
                        }
                    },
                    onDragChanged: { progress in
                        isSeeking = true
                        seekProgress = progress
                    }
                )
                .frame(height: lightStyle ? 10 : 30)
                .shadow(color: musicManager.accentColor.opacity(lightStyle ? 0.2 : 0.3), radius: lightStyle ? 2 : 4, y: 1)

                Text("-\((max(0, musicManager.totalDuration - liveElapsed)).asMinuteSecondClock)")
                    .font(.system(size: lightStyle ? 11 : 10, weight: .medium, design: .monospaced))
                    .foregroundColor(timeColor)
                    .contentTransition(.numericText())
            }
        }
    }
}

struct MusicPlayerView: View {
    @Binding var navigationStack: [NotchWidgetMode]
    @EnvironmentObject var musicManager: MusicManager
    @EnvironmentObject var settings: SettingsModel

    var isLockScreenMode: Bool = false
    var showArtworkSection: Bool = true

    @StateObject private var holdFeedback = MusicHoldFeedbackController()

    private var holdFeedbackIcon: String? { holdFeedback.icon }
    private var holdFeedbackColor: Color { holdFeedback.color }
    private var holdFeedbackButtonID: String? { holdFeedback.buttonID }

    private var isSpotifyOrAppleMusic: Bool {
        let bundleID = musicManager.lastKnownBundleID
        return bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
    }

    private var enabledButtons: [MusicPlayerButtonType] {
        return settings.settings.musicPlayerButtonOrder.filter { type in
            switch type {
            case .shuffle: return isSpotifyOrAppleMusic && settings.settings.musicShuffleButtonEnabled
            case .repeat: return isSpotifyOrAppleMusic && settings.settings.musicRepeatButtonEnabled
            }
        }
    }

    private var primaryButtons: [MusicPlayerButtonType] { Array(enabledButtons.prefix(2)) }
    private var accessoryButtons: [MusicPlayerButtonType] { Array(enabledButtons.dropFirst(2)) }

    var body: some View {
        VStack(spacing: 4) {
            if showArtworkSection {
                artworkSection
                    .padding(.top, 8)
            }

            if musicManager.isPlaying || musicManager.totalDuration > 0 {
                controlsSection
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
        .frame(width: 400).padding(10)
        .animation(.easeInOut(duration: 0.4), value: musicManager.isPlaying)
        .animation(.default, value: enabledButtons)
        .onAppear {
            resetTransientButtonState()
            Task {
                await musicManager.setDetailPlayerOpen(true)
                await musicManager.refreshPlayerUIAfterReturning()
            }
        }
        .onDisappear {
            resetTransientButtonState()
            Task { await musicManager.setDetailPlayerOpen(false) }
        }
    }

    private var artworkSection: some View {
        HStack(spacing: 12) {
            ZStack {
                    if let cover = musicManager.artwork ?? musicManager.appIcon {
                        Image(nsImage: cover)
                            .resizable().aspectRatio(contentMode: .fit).frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .compositingGroup()
                            .shadow(color: musicManager.accentColor.opacity(0.35), radius: 6, y: 3)
                            .id(musicManager.currentTrackArtworkToken)
                    }
                }
                .frame(width: 56, height: 56)
                .onTapGesture {
                    if isLockScreenMode {
                        LockScreenMusicPaneController.shared.open()
                    } else {
                        musicManager.openInSourceApp()
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(musicManager.title ?? String(localized: "Title"))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }

                    Text(musicManager.artist ?? String(localized: "Artist"))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .id("track-\(musicManager.title ?? "")-\(musicManager.artist ?? "")")

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    WaveformView()
                        .environmentObject(musicManager)
                        .scaleEffect(1.05)
                        .transition(.opacity)
                }
                .frame(minWidth: 110, maxWidth: 168, alignment: .trailing)
            }
    }

    private var controlsSection: some View {
        VStack(spacing: 3) {
            PlayerProgressView()

                    HStack {
                        MusicPlayerActionButton(type: primaryButtons.first, size: .primary)
                        Spacer()
                        SeekButton(
                            systemName: "backward.fill",
                            onTap: { Task { await musicManager.previousTrack() } },
                            onSeek: { isForward in Task { await musicManager.seek(by: isForward ? 5.0 : -5.0) } },
                            onLongPressAction: skipHoldClosure(for: .previous),
                            holdAction: skipHoldAction(for: .previous),
                            onHoldBegan: { action in
                                beginHoldFeedback(action: action, buttonID: "previous")
                            },
                            onHoldEnded: endHoldFeedback,
                            displayedSystemName: holdFeedbackButtonID == "previous" ? holdFeedbackIcon : nil
                        )
                        .frame(width: 44, height: 44)
                        .foregroundStyle(holdFeedbackButtonID == "previous" ? holdFeedbackColor : .primary)
                        .help(MusicLongPressUI.skipHelp(primary: String(localized: "music.playback.previous", defaultValue: "Previous"), target: .previous, settings: settings.settings))
                        Spacer()
                        LongPressControlButton(
                            onTap: { Task { await (musicManager.isPlaying ? musicManager.pause() : musicManager.play()) } },
                            onLongPress: accessoryLongPressHandler(for: .playPause),
                            onHoldBegan: { action in beginHoldFeedback(action: action, buttonID: "playPause") },
                            holdAction: settings.settings.resolvedAccessoryHoldAction(for: .playPause),
                            onHoldEnded: endHoldFeedback
                        ) {
                            Image(systemName: holdFeedbackButtonID == "playPause"
                                  ? (holdFeedbackIcon ?? (musicManager.isPlaying ? "pause.fill" : "play.fill"))
                                  : (musicManager.isPlaying ? "pause.fill" : "play.fill"))
                                .font(.system(size: 28))
                                .contentTransition(.symbolEffect(.replace))
                                .foregroundStyle(holdFeedbackButtonID == "playPause" ? holdFeedbackColor : .primary)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .animation(.easeInOut(duration: 0.15), value: musicManager.isPlaying)
                        .animation(.easeInOut(duration: 0.15), value: holdFeedbackIcon)
                        .help(MusicLongPressUI.accessoryHelp(primary: String(localized: "Play / Pause"), target: .playPause, settings: settings.settings))
                        Spacer()
                        SeekButton(
                            systemName: "forward.fill",
                            onTap: { Task { await musicManager.nextTrack() } },
                            onSeek: { isForward in Task { await musicManager.seek(by: isForward ? 5.0 : -5.0) } },
                            onLongPressAction: skipHoldClosure(for: .next),
                            holdAction: skipHoldAction(for: .next),
                            onHoldBegan: { action in
                                beginHoldFeedback(action: action, buttonID: "next")
                            },
                            onHoldEnded: endHoldFeedback,
                            displayedSystemName: holdFeedbackButtonID == "next" ? holdFeedbackIcon : nil
                        )
                        .frame(width: 44, height: 44)
                        .foregroundStyle(holdFeedbackButtonID == "next" ? holdFeedbackColor : .primary)
                        .help(MusicLongPressUI.skipHelp(primary: String(localized: "music.playback.next", defaultValue: "Next"), target: .next, settings: settings.settings))
                        Spacer()
                        MusicPlayerActionButton(type: primaryButtons.dropFirst().first, size: .primary)
                    }
                    .buttonStyle(PlainButtonStyle()).font(.system(size: 22)).foregroundColor(.primary)
                    .padding(.top, accessoryButtons.isEmpty ? 8 : 0)
                    .padding(.bottom, 4)

                    if !accessoryButtons.isEmpty {
                        HStack(spacing: 25) { ForEach(accessoryButtons) { buttonType in MusicPlayerActionButton(type: buttonType, size: .accessory) } }
                        .frame(maxWidth: .infinity).padding(.top, 4)
                    }
        }
    }

    private func accessoryLongPressHandler(for target: MusicLongPressTarget) -> (() -> Void)? {
        guard let action = settings.settings.resolvedAccessoryHoldAction(for: target) else { return nil }
        return holdFeedback.handler(for: action, musicManager: musicManager)
    }

    private func skipHoldAction(for target: MusicLongPressTarget) -> MusicLongPressAction? {
        holdFeedback.skipAction(for: target, settings: settings.settings)
    }

    private func skipHoldClosure(for target: MusicLongPressTarget) -> (() -> Void)? {
        guard let action = skipHoldAction(for: target) else { return nil }
        return holdFeedback.handler(for: action, musicManager: musicManager)
    }

    private func beginHoldFeedback(action: MusicLongPressAction, buttonID: String) {
        holdFeedback.begin(action: action, buttonID: buttonID, musicManager: musicManager)
    }

    private func endHoldFeedback() {
        holdFeedback.end()
    }

    private func resetTransientButtonState() {
        holdFeedback.reset()
    }

    @ViewBuilder
    private func MusicPlayerActionButton(type: MusicPlayerButtonType?, size: ButtonSize) -> some View {
        if let type = type {
            let iconSize: CGFloat = size == .primary ? 18 : 16
            let frameSize: CGFloat = size == .primary ? 40 : 30

            switch type {
            case .shuffle:
                LongPressControlButton(
                    onTap: { Task { await musicManager.toggleShuffle() } },
                    onLongPress: accessoryLongPressHandler(for: .shuffle),
                    onHoldBegan: { action in beginHoldFeedback(action: action, buttonID: "shuffle") },
                    holdAction: settings.settings.resolvedAccessoryHoldAction(for: .shuffle),
                    onHoldEnded: endHoldFeedback
                ) {
                    Image(systemName: holdFeedbackButtonID == "shuffle"
                          ? (holdFeedbackIcon ?? type.systemImage)
                          : type.systemImage)
                        .font(.system(size: iconSize))
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundColor(
                    holdFeedbackButtonID == "shuffle"
                        ? holdFeedbackColor
                        : (musicManager.shuffleState ? .green : .secondary)
                )
                .frame(width: frameSize, height: frameSize)
                .animation(.easeInOut, value: musicManager.shuffleState)
                .animation(.easeInOut(duration: 0.15), value: holdFeedbackIcon)
                .help(MusicLongPressUI.accessoryHelp(primary: String(localized: "Shuffle"), target: .shuffle, settings: settings.settings))

            case .repeat:
                LongPressControlButton(
                    onTap: { Task { await musicManager.cycleRepeatMode() } },
                    onLongPress: accessoryLongPressHandler(for: .repeatMode),
                    onHoldBegan: { action in beginHoldFeedback(action: action, buttonID: "repeat") },
                    holdAction: settings.settings.resolvedAccessoryHoldAction(for: .repeatMode),
                    onHoldEnded: endHoldFeedback
                ) {
                    Image(systemName: holdFeedbackButtonID == "repeat"
                          ? (holdFeedbackIcon ?? (musicManager.repeatState == .track ? "repeat.1" : "repeat"))
                          : (musicManager.repeatState == .track ? "repeat.1" : "repeat"))
                        .font(.system(size: iconSize))
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundColor(holdFeedbackButtonID == "repeat"
                                 ? holdFeedbackColor
                                 : (musicManager.repeatState != .off ? .green : .secondary))
                .frame(width: frameSize, height: frameSize)
                .animation(.easeInOut, value: musicManager.repeatState)
                .animation(.easeInOut(duration: 0.15), value: holdFeedbackIcon)
                .help(MusicLongPressUI.accessoryHelp(primary: String(localized: "Repeat"), target: .repeatMode, settings: settings.settings))
            }
        } else {
            Rectangle().fill(Color.clear).frame(width: 40, height: 40)
        }
    }

    enum ButtonSize {
        case primary, accessory
        var style: AnyButtonStyle { AnyButtonStyle(BlurButtonStyle()) }
    }
    struct AnyButtonStyle: ButtonStyle {
        private let _makeBody: (Configuration) -> AnyView
        init<S: ButtonStyle>(_ style: S) { _makeBody = { configuration in AnyView(style.makeBody(configuration: configuration)) } }
        func makeBody(configuration: Configuration) -> some View { _makeBody(configuration) }
    }
}

// MARK: - View Modifiers
struct PressableButton: ViewModifier {
    @Binding var isPressing: Bool
    var size: MusicPlayerView.ButtonSize
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressing ? 0.9 : 1.0)
            .blur(radius: isPressing ? 2 : 0)
            .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: isPressing)
    }
}

struct NotchMediaSourceSwitcher: View {
    @EnvironmentObject var musicManager: MusicManager

    private var keys: [String] {
        musicManager.activeMediaSources.keys.sorted()
    }

    var body: some View {
        let sourceKeys = keys
        let selectedKey = musicManager.currentSourceKey
        if sourceKeys.count > 1, let fallbackKey = sourceKeys.first {
            HStack(spacing: 3) {
                ForEach(sourceKeys, id: \.self) { key in
                    let selected = (selectedKey ?? fallbackKey) == key
                    Button {
                        musicManager.selectSource(key: key, userInitiated: true)
                    } label: {
                        Image(nsImage: musicManager.sourceAppIcon(for: key))
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(3)
                            .background(
                                Circle()
                                    .fill(selected ? Color.white.opacity(0.22) : Color.clear)
                            )
                            .opacity(selected ? 1.0 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .help(label(for: key))
                }
            }
            .padding(2)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .fixedSize()
            .animation(.easeInOut(duration: 0.2), value: selectedKey)
            .animation(.easeInOut(duration: 0.2), value: sourceKeys.joined(separator: "|"))
            .id("sources-\(sourceKeys.joined(separator: "|"))-\(selectedKey ?? "")")
        }
    }

    private func label(for key: String) -> String {
        if key.lowercased().contains("spotify") { return "Spotify" }
        if let track = musicManager.activeMediaSources[key] {
            return musicManager.appName(for: track.payload.bundleIdentifier)
        }
        return String(localized: "App")
    }
}

// MARK: - Consolidated from MusicWidgetView.swift

struct MusicWidgetView: View {
    @Environment(\.navigationStack) var navigationStack
    @EnvironmentObject var musicManager: MusicManager
    @EnvironmentObject var settings: SettingsModel
    @State private var isHoveringArtwork = false

    var onExpand: (() -> Void)? = nil

    var body: some View {
        if let title = musicManager.title, !title.isEmpty {
            Button {
                if let onExpand {
                    onExpand()
                } else {
                    navigationStack.wrappedValue.append(.musicPlayer)
                }
            } label: {
                HStack(alignment: .center, spacing: 16) {
                    albumArt

                    VStack(alignment: .leading, spacing: 8) {
                        MusicInfoView(
                            title: musicManager.title,
                            album: musicManager.album,
                            artist: musicManager.artist
                        )
                        .animation(.easeInOut(duration: 0.2), value: musicManager.title)
                        .animation(.easeInOut(duration: 0.2), value: musicManager.artist)
                        .animation(.easeInOut(duration: 0.2), value: musicManager.album)

                        MusicControlsView(
                            isPlaying: musicManager.isPlaying,
                            onPrevious: { Task { await musicManager.previousTrack() } },
                            onPlayPause: { Task { await (musicManager.isPlaying ? musicManager.pause() : musicManager.play()) } },
                            onNext: { Task { await musicManager.nextTrack() } }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
                .frame(maxWidth: 300)
                .fixedSize()
            }
            .buttonStyle(.plain)
        } else {
            OpenPlayerView(
                player: settings.settings.defaultMusicPlayer,
                action: openDefaultPlayer
            )
        }
    }

    private var albumArt: some View {
        Image(nsImage: musicManager.artwork ?? musicManager.appIcon ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: String(localized: "Album art"))!)
            .resizable().aspectRatio(contentMode: .fill)
            .frame(width: 100, height: 100).cornerRadius(30)
            .shadow(color: musicManager.accentColor.opacity(0.7), radius: 8, y: 5)
            .onHover { hovering in
                self.isHoveringArtwork = hovering
            }
    }

    private func openDefaultPlayer() {
        settings.settings.defaultMusicPlayer.open()
    }
}

private struct OpenPlayerView: View {
    let player: DefaultMusicPlayer
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.white.opacity(0.8))

            Button(action: action) {
                Text("Open \(player.displayName)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300, height: 100)
    }
}

private struct MusicInfoView: View {
    let title: String?
    let album: String?
    let artist: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }

            if let album = album, !album.isEmpty, album != title {
                Text(album)
                    .font(.system(size: 14, weight: .medium))
            }
            if let artist = artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.top, 8)
        .minimumScaleFactor(0.8)
    }
}

private struct MusicControlsView: View {
    let isPlaying: Bool
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    @EnvironmentObject var musicManager: MusicManager
    @EnvironmentObject var settings: SettingsModel

    let buttonHitboxSize: CGFloat = 37

    var body: some View {
        HStack(spacing: 0) {
            SeekButton(
                systemName: "backward.end.fill",
                onTap: onPrevious,
                onSeek: { isForward in
                    Task { await musicManager.seek(by: isForward ? 5.0 : -5.0) }
                },
                onLongPressAction: MusicLongPressUI.skipHoldHandler(
                    for: .previous,
                    settings: settings.settings,
                    musicManager: musicManager
                )
            )
            .frame(width: buttonHitboxSize, height: buttonHitboxSize)
            .help(MusicLongPressUI.skipHelp(primary: String(localized: "music.playback.previous", defaultValue: "Previous"), target: .previous, settings: settings.settings))

            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: buttonHitboxSize, height: buttonHitboxSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SeekButton(
                systemName: "forward.end.fill",
                onTap: onNext,
                onSeek: { isForward in
                    Task { await musicManager.seek(by: isForward ? 5.0 : -5.0) }
                },
                onLongPressAction: MusicLongPressUI.skipHoldHandler(
                    for: .next,
                    settings: settings.settings,
                    musicManager: musicManager
                )
            )
            .frame(width: buttonHitboxSize, height: buttonHitboxSize)
            .help(MusicLongPressUI.skipHelp(primary: String(localized: "music.playback.next", defaultValue: "Next"), target: .next, settings: settings.settings))
        }
        .font(.system(size: 16))
        .foregroundColor(.white)
    }
}

// MARK: - Consolidated from WaveformView.swift

struct CoreAnimationWaveformView: NSViewRepresentable, Equatable {
    var isPlaying: Bool
    var barCount: Int
    var volumeScale: CGFloat
    var barThickness: CGFloat
    var leftGradientColor: Color
    var rightGradientColor: Color

    static func == (lhs: CoreAnimationWaveformView, rhs: CoreAnimationWaveformView) -> Bool {
        return lhs.isPlaying == rhs.isPlaying &&
               lhs.barCount == rhs.barCount &&
               lhs.volumeScale == rhs.volumeScale &&
               lhs.barThickness == rhs.barThickness &&
               lhs.leftGradientColor == rhs.leftGradientColor &&
               lhs.rightGradientColor == rhs.rightGradientColor
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        context.coordinator.setupLayers(in: view.layer!, with: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(isPlaying: isPlaying)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 22, height: proposal.height ?? 22)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator {
        var parent: CoreAnimationWaveformView
        var maskLayers: [CALayer] = []
        private var hasSetup = false

        private var lastIsPlaying: Bool? = nil
        private var lastLeftColor: Color? = nil
        private var lastRightColor: Color? = nil
        private var lastVolumeScale: CGFloat? = nil

        init(_ parent: CoreAnimationWaveformView) {
            self.parent = parent
        }

        static func withoutImplicitAnimations(_ body: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body()
            CATransaction.commit()
        }

        func setupLayers(in parentLayer: CALayer, with context: Context) {
            guard !hasSetup else { return }
            hasSetup = true

            let totalSpacing = CGFloat(parent.barCount - 1) * 3.0
            let totalWidth = CGFloat(parent.barCount) * parent.barThickness + totalSpacing
            var xOffset = (parentLayer.bounds.width - totalWidth) / 2.0

            for _ in 0..<parent.barCount {
                let barContainerLayer = CALayer()
                barContainerLayer.frame = CGRect(x: xOffset, y: 0, width: parent.barThickness, height: parentLayer.bounds.height)

                let gradientLayer = CAGradientLayer()
                gradientLayer.frame = barContainerLayer.bounds
                gradientLayer.colors = [
                    NSColor(parent.leftGradientColor).cgColor,
                    NSColor(parent.rightGradientColor).cgColor
                ]
                gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
                gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

                let maskLayer = CALayer()
                maskLayer.backgroundColor = NSColor.black.cgColor
                maskLayer.cornerRadius = parent.barThickness / 2
                maskLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                maskLayer.position = CGPoint(
                    x: barContainerLayer.bounds.midX,
                    y: barContainerLayer.bounds.midY
                )
                maskLayer.bounds = CGRect(x: 0, y: 0, width: parent.barThickness, height: parent.barThickness)

                gradientLayer.mask = maskLayer
                barContainerLayer.addSublayer(gradientLayer)
                parentLayer.addSublayer(barContainerLayer)

                maskLayers.append(maskLayer)

                xOffset += parent.barThickness + 3.0
            }
        }

        func update(isPlaying: Bool) {
            let colorsChanged = parent.leftGradientColor != lastLeftColor || parent.rightGradientColor != lastRightColor
            let playStateChanged = isPlaying != lastIsPlaying
            let scaleChanged = parent.volumeScale != lastVolumeScale

            guard colorsChanged || playStateChanged || scaleChanged else { return }

            lastLeftColor = parent.leftGradientColor
            lastRightColor = parent.rightGradientColor
            lastIsPlaying = isPlaying
            lastVolumeScale = parent.volumeScale

            let minHeight = parent.barThickness
            let animationKey = "pathAnimation"

            for (index, maskLayer) in maskLayers.enumerated() {
                if let gradient = (maskLayer.superlayer as? CAGradientLayer), colorsChanged {
                     gradient.colors = [
                        NSColor(parent.leftGradientColor).cgColor,
                        NSColor(parent.rightGradientColor).cgColor
                    ]
                }

                if isPlaying {
                    if playStateChanged || scaleChanged || maskLayer.animation(forKey: animationKey) == nil {
                        maskLayer.removeAnimation(forKey: animationKey)

                        let highValues = [0.5, 0.8, 0.65, 0.7, 0.9, 0.6]
                        let speeds = [1.8, 1.2, 1.4, 1.6, 1.0, 1.7]

                        let maxHeight = 22.0
                        let targetHeight = minHeight + (maxHeight - minHeight) * (highValues[index] * parent.volumeScale)

                        Self.withoutImplicitAnimations {
                            maskLayer.cornerRadius = parent.barThickness / 2
                            maskLayer.bounds = CGRect(x: 0, y: 0, width: parent.barThickness, height: minHeight)
                        }

                        let animation = CABasicAnimation(keyPath: "bounds.size.height")
                        animation.fromValue = minHeight
                        animation.toValue = targetHeight
                        animation.duration = 1.5 / speeds[index]
                        animation.autoreverses = true
                        animation.repeatCount = .infinity
                        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

                        maskLayer.add(animation, forKey: animationKey)
                    }
                } else if playStateChanged || maskLayer.animation(forKey: animationKey) != nil {
                    maskLayer.removeAllAnimations()
                    Self.withoutImplicitAnimations {
                        maskLayer.bounds = CGRect(x: 0, y: 0, width: parent.barThickness, height: minHeight)
                    }
                }
            }
        }
    }
}

struct WaveformView: View {
    @EnvironmentObject var musicManager: MusicManager
    @EnvironmentObject var settingsModel: SettingsModel

    @State private var isHovering = false
    @State private var volumeScale: CGFloat = 0.7

    enum TransientIcon: Equatable {
        case paused, played, skippedForward, skippedBackward

        var systemName: String {
            switch self {
            case .paused: return "pause.fill"
            case .played: return "play"
            case .skippedForward: return "forward.end.fill"
            case .skippedBackward: return "backward.end.fill"
            }
        }
    }

    private var barCount: Int {
        min(max(settingsModel.settings.waveformBarCount, 1), 6)
    }

    private var minHeight: CGFloat {
        settingsModel.settings.waveformBarThickness
    }

    private var waveformGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [musicManager.leftGradientColor, musicManager.rightGradientColor]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ZStack {
            if isHovering {
                Button(action: {
                    Task {
                        if musicManager.isPlaying {
                            await musicManager.pause()
                        } else {
                            await musicManager.play()
                        }
                    }
                }) {
                    Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(musicManager.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))

            } else if let icon = musicManager.transientIcon {
                iconBody(systemName: icon.systemName)

            } else if musicManager.isPlaying && !settingsModel.settings.useStaticWaveform {
                animatedWaveformBody

            } else {
                staticWaveformBody
            }
        }
        .frame(width: 22, height: 22, alignment: .center)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: musicManager.isPlaying)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .animation(.default, value: musicManager.transientIcon)
        .onHover { hovering in
            self.isHovering = hovering
        }
        .onAppear(perform: setupInitialState)
        .onReceive(musicManager.volumePublisher.receive(on: RunLoop.main)) { newVolume in
            if settingsModel.settings.musicWaveformIsVolumeSensitive {
                self.volumeScale = CGFloat(newVolume)
            }
        }
        .onChange(of: settingsModel.settings.musicWaveformIsVolumeSensitive) { _, isSensitive in
            if !isSensitive {
                self.volumeScale = 0.7
            } else {
                self.volumeScale = CGFloat(musicManager.systemVolume)
            }
        }
    }

    private func setupInitialState() {
        if settingsModel.settings.musicWaveformIsVolumeSensitive {
            volumeScale = CGFloat(musicManager.systemVolume)
        } else {
            volumeScale = 0.7
        }
    }

    private var animatedWaveformBody: some View {
        CoreAnimationWaveformView(
            isPlaying: musicManager.isPlaying,
            barCount: barCount,
            volumeScale: volumeScale,
            barThickness: settingsModel.settings.waveformBarThickness,
            leftGradientColor: musicManager.leftGradientColor,
            rightGradientColor: musicManager.rightGradientColor
        )
    }

    private var staticWaveformBody: some View {
        let barFill = settingsModel.settings.waveformUseGradient ?
            AnyShapeStyle(waveformGradient) :
            AnyShapeStyle(musicManager.accentColor)

        return HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { _ in
                Capsule()
                    .fill(barFill)
                    .frame(width: settingsModel.settings.waveformBarThickness, height: minHeight)
            }
        }
        .frame(width: 18, height: 22)
        .transition(.opacity)
    }

    private func iconBody(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(musicManager.accentColor)
            .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }
}
