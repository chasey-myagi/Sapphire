//
//  NotchWidgetView.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2025-11-16

import Combine
import SwiftUI

enum MusicWidgetVisibilityPolicy {
    static func shouldShow(
        isEnabled: Bool,
        hideWhenNotPlaying: Bool,
        isPlaying: Bool,
        hidePausedSpotifyWhenIdle: Bool,
        isSpotifyPausedWithNoOtherPlayback: Bool
    ) -> Bool {
        guard isEnabled else { return false }
        if hideWhenNotPlaying && !isPlaying { return false }
        if hidePausedSpotifyWhenIdle && isSpotifyPausedWithNoOtherPlayback { return false }
        return true
    }
}

private struct WidgetViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 720
}

private struct WidgetStripHoverKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var onWidgetStripHover: (Bool) -> Void {
        get { self[WidgetStripHoverKey.self] }
        set { self[WidgetStripHoverKey.self] = newValue }
    }

    var widgetViewportWidth: CGFloat {
        get { self[WidgetViewportWidthKey.self] }
        set { self[WidgetViewportWidthKey.self] = newValue }
    }
}

struct BoundedWidgetStrip<Content: View>: View {
    let maximumWidth: CGFloat
    @State private var contentSize: CGSize
    let content: Content

    init(maximumWidth: CGFloat, initialWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.maximumWidth = maximumWidth
        _contentSize = State(initialValue: CGSize(width: max(1, initialWidth), height: 100))
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal) {
            content
                .fixedSize(horizontal: true, vertical: true)
                .measureIdealSize(into: $contentSize)
        }
        .frame(width: max(1, min(maximumWidth, contentSize.width)), height: max(1, contentSize.height))
    }
}

private struct NavigationStackKey: EnvironmentKey {
    static let defaultValue: Binding<[NotchWidgetMode]> = .constant([.defaultWidgets])
}
private struct ActiveDropZoneKey: EnvironmentKey {
    static let defaultValue: Binding<DropZone?> = .constant(nil)
}

private struct OnActiveSnapZoneChangeKey: EnvironmentKey {
    static let defaultValue: (SnapZone?) -> Void = { _ in }
}

private struct OnDropZoneFramesChangeKey: EnvironmentKey {
    static let defaultValue: ([DropZone: CGRect]) -> Void = { _ in }
}

private struct OnSnapZoneHitRegionsChangeKey: EnvironmentKey {
    static let defaultValue: ([SnapZoneHitRegion]) -> Void = { _ in }
}

private struct FileDragModeKey: EnvironmentKey {
    static let defaultValue: FileDragMode = .newFile
}

private struct IsCalendarHoveredKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var navigationStack: Binding<[NotchWidgetMode]> {
        get { self[NavigationStackKey.self] }
        set { self[NavigationStackKey.self] = newValue }
    }
    var activeDropZone: Binding<DropZone?> {
        get { self[ActiveDropZoneKey.self] }
        set { self[ActiveDropZoneKey.self] = newValue }
    }
    var onActiveSnapZoneChange: (SnapZone?) -> Void {
        get { self[OnActiveSnapZoneChangeKey.self] }
        set { self[OnActiveSnapZoneChangeKey.self] = newValue }
    }
    var onDropZoneFramesChange: ([DropZone: CGRect]) -> Void {
        get { self[OnDropZoneFramesChangeKey.self] }
        set { self[OnDropZoneFramesChangeKey.self] = newValue }
    }
    var onSnapZoneHitRegionsChange: ([SnapZoneHitRegion]) -> Void {
        get { self[OnSnapZoneHitRegionsChangeKey.self] }
        set { self[OnSnapZoneHitRegionsChangeKey.self] = newValue }
    }
    var fileDragMode: FileDragMode {
        get { self[FileDragModeKey.self] }
        set { self[FileDragModeKey.self] = newValue }
    }
    var isCalendarHovered: Binding<Bool> {
        get { self[IsCalendarHoveredKey.self] }
        set { self[IsCalendarHoveredKey.self] = newValue }
    }
}

@MainActor
final class NotchDragLocationState: ObservableObject {
    @Published private(set) var location: CGPoint?

    func update(_ newLocation: CGPoint?) {
        guard location != newLocation else { return }
        location = newLocation
    }
}

struct NotchWidgetView: View {
    @Environment(\.navigationStack) var navigationStack
    @Environment(\.activeDropZone) var activeDropZone
    @Environment(\.onActiveSnapZoneChange) var onActiveSnapZoneChange
    @Environment(\.onDropZoneFramesChange) var onDropZoneFramesChange
    @Environment(\.onSnapZoneHitRegionsChange) var onSnapZoneHitRegionsChange
    @Environment(\.fileDragMode) var fileDragMode

    private let calendarViewModel: InteractiveCalendarViewModel

    private var currentMode: NotchWidgetMode {
        navigationStack.wrappedValue.last ?? .defaultWidgets
    }
    @State private var displayedMode: NotchWidgetMode = .defaultWidgets

    @State private var blurRadius: CGFloat = 20
    @State private var isScaledIn: Bool = false
    @State private var isFadedIn: Bool = false
    @State private var isPositioned: Bool = false

    init(calendarViewModel: InteractiveCalendarViewModel) {
        self.calendarViewModel = calendarViewModel
    }

    var body: some View {
        ZStack {
            contentSwitch(for: displayedMode)
                .id(displayedMode)
                .compositingGroup()
                .blur(radius: blurRadius)
                .scaleEffect(isScaledIn ? 1.0 : 0.7, anchor: .top)
                .opacity(isFadedIn ? 1.0 : 0.0)
                .offset(y: isPositioned ? 0 : -50)
        }
        .onAppear {
            self.displayedMode = self.currentMode
        }
        .task {
            let animation: Animation
            if self.currentMode == .defaultWidgets {
                animation = .interpolatingSpring(stiffness: 230, damping: 22)
            } else {
                animation = .interpolatingSpring(stiffness: 220, damping: 18)
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(animation) {
                self.isScaledIn = true
                self.isPositioned = true
                self.isFadedIn = true
            }
            withAnimation(.easeOut(duration: 0.6)) {
                self.blurRadius = 0
            }
        }
        .onChange(of: currentMode) {
            withAnimation(.easeIn(duration: 0.2)) {
                self.isFadedIn = false
                self.blurRadius = 20
            }

            self.displayedMode = self.currentMode
            self.isScaledIn = false
            self.isPositioned = false

            let animation: Animation
            if self.currentMode == .defaultWidgets {
                animation = .interpolatingSpring(stiffness: 220, damping: 22)
            } else {
                animation = .interpolatingSpring(stiffness: 220, damping: 20)
            }

            withAnimation(animation) {
                self.isScaledIn = true
                self.isPositioned = true
                self.isFadedIn = true
            }
            withAnimation(.easeOut(duration: 0.6)) {
                self.blurRadius = 0
            }
        }
        .notchHorizontalPadding()
    }

    @ViewBuilder
    private func contentSwitch(for mode: NotchWidgetMode) -> some View {
        switch mode {
        case .defaultWidgets:
            NotchDefaultWidgetsView(calendarViewModel: calendarViewModel)
        case .musicApiKeysMissing:
            ApiKeysMissingView(navigationStack: navigationStack)
        case .musicPlayer:
            MusicPlayerView(navigationStack: navigationStack)
        case .sportsPlayer:
            SportsPlayerView(navigationStack: navigationStack)
        case .notesPlayer:
            NotesPlayerView(navigationStack: navigationStack)
        case .clipboardPlayer:
            ClipboardPlayerView(navigationStack: navigationStack)
        case .mirrorPlayer:
            MirrorPlayerView()
        case .musicLoginPrompt:
            LoginPromptView(navigationStack: navigationStack)
        case .musicQueueAndPlaylists:
            QueueAndPlaylistsView(navigationStack: navigationStack)
        case .musicDevices:
            QueueAndPlaylistsView(navigationStack: navigationStack)
        case .musicLyrics:
            LyricsView()
        case .musicPlaylistDetail(let playlist):
            PlaylistView(playlist: playlist)
        case .musicArtistDetail(let uri, let name):
            SpotifyArtistDetailView(uri: uri, name: name, navigationStack: navigationStack)
        case .musicAlbumDetail(let uri, let name):
            SpotifyAlbumDetailView(uri: uri, name: name, navigationStack: navigationStack)
        case .nearDrop:
            FileTaskView(navigationStack: navigationStack)
        case .weatherPlayer:
            WeatherPlayerView()
        case .calendarPlayer:
            CalendarDetailView(viewModel: calendarViewModel)
        case .timerDetailView:
            TimerDetailView(navigationStack: navigationStack)
        case .snapZones:
            SnapZonesWidgetView(
                onActiveZoneChange: onActiveSnapZoneChange,
                onHitRegionsChange: onSnapZoneHitRegionsChange
            )
        case .fileShelf:
            FileShelfView()
        case .fileShelfLanding:
            FileDragLandingView(
                mode: fileDragMode,
                activeZone: activeDropZone,
                onZoneFramesChange: onDropZoneFramesChange
            )
        case .fileActionPreview:
            FileActionPreviewContent()
        case .multiAudio:
            MultiAudioView(navigationStack: navigationStack)
        case .multiAudioDeviceAdjust(let device):
            DeviceAdjustView(device: device)
        case .multiAudioEQ(let device):
            DeviceEQView(device: device)
        case .multiAudioAppEQ(let bundleID, let appName):
            AppEQView(bundleID: bundleID, appName: appName)
        case .multiAudioApp8D(let bundleID, let appName):
            EightDAudioView(bundleID: bundleID, appName: appName)
        case .multiAudioAppSurround(let bundleID, let appName):
            SurroundAudioView(bundleID: bundleID, appName: appName)

        case .dragActivated:
            Color.clear
                .frame(width: 300, height: 200)
        case .circleToSearch:
            CircleToSearchResultsView(navigationStack: navigationStack)
        case .updateAvailable:
            UpdateAvailableWidgetView()
        case .focusSessionDetailView:
            FocusSessionDetailView(navigationStack: navigationStack)
        case .batteryDetailView:
            BatteryDetailView()
        case .storageDetailView:
            StorageDetailView()
        }
    }

}

private struct NotchDefaultWidgetsView: View {
    @Environment(\.navigationStack) private var navigationStack
    @Environment(\.isCalendarHovered) private var isCalendarHovered
    @Environment(\.widgetViewportWidth) private var viewportWidth
    @Environment(\.onWidgetStripHover) private var onStripHover
    @EnvironmentObject private var settings: SettingsModel
    @State private var musicVisibility: MusicWidgetVisibilitySnapshot

    let calendarViewModel: InteractiveCalendarViewModel
    private let musicWidget = MusicManager.shared

    init(calendarViewModel: InteractiveCalendarViewModel) {
        self.calendarViewModel = calendarViewModel
        _musicVisibility = State(
            initialValue: MusicWidgetVisibilitySnapshot(manager: MusicManager.shared)
        )
    }

    private var enabledAndOrderedWidgets: [WidgetType] {
        WidgetLayoutPolicy.enabledWidgets(
            settings: settings.settings,
            isMusicPlaying: musicVisibility.isPlaying,
            isSpotifyPausedWithNoOtherPlayback: musicVisibility.isSpotifyPausedWithNoOtherPlayback
        )
    }

    var body: some View {
        let widgets = enabledAndOrderedWidgets
        BoundedWidgetStrip(
            maximumWidth: viewportWidth,
            initialWidth: WidgetLayoutPolicy.totalWidth(for: widgets, showDividers: settings.settings.showDividersBetweenWidgets)
        ) {
            HStack(spacing: WidgetLayoutPolicy.interWidgetSpacing) {
                ForEach(widgets) { widgetType in
                    widgetView(for: widgetType)
                        .id(widgetType)

                    if widgetType != widgets.last && settings.settings.showDividersBetweenWidgets {
                        Divider()
                            .frame(height: 60)
                            .background(Color.white.opacity(0.3))
                    }
                }
            }
        }
        .onHover(perform: onStripHover)
        .onDisappear { onStripHover(false) }
        .onAppear(perform: refreshMusicVisibility)
        .onReceive(
            musicWidget.objectWillChange
                .debounce(for: .milliseconds(1), scheduler: RunLoop.main)
        ) { _ in
            refreshMusicVisibility()
        }
    }

    private func refreshMusicVisibility() {
        let snapshot = MusicWidgetVisibilitySnapshot(manager: musicWidget)
        guard snapshot != musicVisibility else { return }
        musicVisibility = snapshot
    }

    @ViewBuilder
    private func widgetView(for widgetType: WidgetType) -> some View {
        switch widgetType {
        case .music:
            MusicWidgetView()
                .onTapGesture {
                    if settings.settings.musicOpenOnClick {
                        Task {
                            try? await Task.sleep(for: .seconds(NotchConfiguration.primaryWidgetSwitchDelay))
                            navigationStack.wrappedValue.append(NotchWidgetMode.musicPlayer)
                        }
                    }
                }
        case .weather:
            WeatherWidgetView()
                .onTapGesture {
                    if settings.settings.weatherOpenOnClick {
                        Task {
                            try? await Task.sleep(for: .seconds(NotchConfiguration.primaryWidgetSwitchDelay))
                            navigationStack.wrappedValue.append(NotchWidgetMode.weatherPlayer)
                        }
                    }
                }
        case .sports:
            SportsWidgetView()
                .onTapGesture {
                    if settings.settings.sportsOpenOnClick {
                        Task {
                            try? await Task.sleep(for: .seconds(NotchConfiguration.primaryWidgetSwitchDelay))
                            navigationStack.wrappedValue.append(NotchWidgetMode.sportsPlayer)
                        }
                    }
                }
        case .calendar:
            CalendarWidgetView(viewModel: calendarViewModel)
                .onTapGesture {
                    if settings.settings.calendarOpenOnClick {
                        Task {
                            try? await Task.sleep(for: .seconds(NotchConfiguration.primaryWidgetSwitchDelay))
                            navigationStack.wrappedValue.append(NotchWidgetMode.calendarPlayer)
                        }
                    }
                }
                .onHover { hovering in
                    self.isCalendarHovered.wrappedValue = hovering
                }
        case .shortcuts:
            ShortcutWidgetView()
        case .notes:
            NotesWidgetView()
                .onTapGesture {
                    if settings.settings.notesOpenOnClick {
                        Task {
                            try? await Task.sleep(for: .seconds(NotchConfiguration.primaryWidgetSwitchDelay))
                            navigationStack.wrappedValue.append(NotchWidgetMode.notesPlayer)
                        }
                    }
                }
        case .clipboard:
            ClipboardWidgetView()
                .onTapGesture {
                    if settings.settings.clipboardOpenOnClick {
                        Task {
                            try? await Task.sleep(for: .seconds(NotchConfiguration.primaryWidgetSwitchDelay))
                            navigationStack.wrappedValue.append(NotchWidgetMode.clipboardPlayer)
                        }
                    }
                }
        case .mirror:
            MirrorWidgetView()
        case .focusSession:
            FocusWidgetView()
        case .timer:
            TimerWidgetView()
        case .battery:
            BatteryWidgetView()
        case .storage:
            StorageWidgetView()
                .onTapGesture {
                    if settings.settings.storageOpenOnClick {
                        Task {
                            try? await Task.sleep(for: .seconds(NotchConfiguration.primaryWidgetSwitchDelay))
                            navigationStack.wrappedValue.append(NotchWidgetMode.storageDetailView)
                        }
                    }
                }
        }
    }
}

private struct MusicWidgetVisibilitySnapshot: Equatable {
    let isPlaying: Bool
    let isSpotifyPausedWithNoOtherPlayback: Bool

    @MainActor
    init(manager: MusicManager) {
        isPlaying = manager.isPlaying
        isSpotifyPausedWithNoOtherPlayback = manager.isSpotifyPausedWithNoSystemMediaPlaying
    }
}

private struct FileActionPreviewContent: View {
    @Environment(\.navigationStack) private var navigationStack
    @EnvironmentObject private var fileShelfState: FileShelfState

    var body: some View {
        if let item = fileShelfState.selectedItemForPreview {
            FileActionView(item: item, onDismiss: {
                if navigationStack.wrappedValue.last == .fileActionPreview {
                    navigationStack.wrappedValue.removeLast()
                }
            })
        } else {
            FileShelfView()
        }
    }
}

struct NotchCornerRadiusKey: EnvironmentKey {
    static let defaultValue: CGFloat = 10.0
}

extension EnvironmentValues {
    var notchCornerRadius: CGFloat {
        get { self[NotchCornerRadiusKey.self] }
        set { self[NotchCornerRadiusKey.self] = newValue }
    }
}
