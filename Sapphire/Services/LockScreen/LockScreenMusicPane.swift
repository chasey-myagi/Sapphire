//
//  LockScreenMusicPane.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-08-10

import SwiftUI
import AppKit

private struct LockScreenPaneClickPassthrough: NSViewRepresentable {
    let interactive: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.ignoresMouseEvents = !interactive }
    }
}

// MARK: - Tabs

enum LockScreenMusicTab: String, CaseIterable, Identifiable {
    case nowPlaying

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "Overview"
        }
    }

    var systemImage: String {
        switch self {
        case .nowPlaying: "square.grid.2x2"
        }
    }
}

// MARK: - Controller

@MainActor
final class LockScreenMusicPaneController: ObservableObject {
    static let shared = LockScreenMusicPaneController()
    @Published var isPresented = false
    @Published var selectedTab: LockScreenMusicTab = .nowPlaying
    private init() {}
    func open() { withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { isPresented = true; selectedTab = .nowPlaying } }
    func close() { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { isPresented = false } }
    func selectTab(_ tab: LockScreenMusicTab) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            selectedTab = tab
        }
    }
    func reset() { isPresented = false; selectedTab = .nowPlaying }
}

// MARK: - Main Pane

struct LockScreenFullScreenMusicPane: View {
    @ObservedObject private var controller = LockScreenMusicPaneController.shared
    @EnvironmentObject var musicManager: MusicManager
    @EnvironmentObject var settings: SettingsModel
    @State private var dummyNavigationStack: [NotchWidgetMode] = []
    @State private var desktopWallpaper: NSImage?
    @StateObject private var navigationManager = LockScreenNavigationManager()
    @State private var isAnimatingIn = false
    @Namespace private var tabNamespace
    private var screenSize: CGSize { NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900) }

    var body: some View {
        ZStack {
            if controller.isPresented { paneContent.transition(.opacity) }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .opacity(controller.isPresented ? 1 : 0)
        .allowsHitTesting(controller.isPresented)
        .background(LockScreenPaneClickPassthrough(interactive: controller.isPresented))
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: controller.isPresented)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.selectedTab)
        .onAppear { isAnimatingIn = controller.isPresented }
        .onChange(of: controller.isPresented) { _, presented in
            isAnimatingIn = false
            if presented { withAnimation(.spring(response: 0.52, dampingFraction: 0.76).delay(0.04)) { isAnimatingIn = true } }
        }
        .onChange(of: musicManager.isPlaying) { _, playing in
            if !playing && (musicManager.title?.isEmpty ?? true) { controller.close() }
        }
    }

    private var paneContent: some View {
        ZStack {
            ambientBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 28)
                    .padding(.horizontal, 40)

                tabBar
                    .padding(.horizontal, 40)
                    .padding(.top, 14)

                Spacer(minLength: 16)

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer(minLength: 16)

                LockScreenMusicDock(navigationStack: $dummyNavigationStack, navigationManager: navigationManager)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 36)
            }
            .opacity(isAnimatingIn ? 1 : 0)
            .scaleEffect(isAnimatingIn ? 1 : 0.97)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            desktopWallpaper = Self.loadDesktopWallpaper()
        }
    }

    private static func loadDesktopWallpaper() -> NSImage? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: { controller.close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text(musicManager.title ?? String(localized: "Not Playing"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(musicManager.artist ?? "")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer()

            Color.clear.frame(width: 38, height: 38)
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        let tabs = visibleTabs
        return HStack(spacing: 0) {
            Spacer()
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    Button {
                        if controller.selectedTab == tab, tab == .nowPlaying { controller.close() }
                        else { controller.selectTab(tab) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 11, weight: .semibold))
                            Text(tab.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            controller.selectedTab == tab
                                ? AnyView(Capsule().fill(.white.opacity(0.18)))
                                : AnyView(Capsule().fill(Color.clear))
                        )
                        .foregroundStyle(controller.selectedTab == tab ? .white : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            Spacer()
        }
    }

    private var visibleTabs: [LockScreenMusicTab] {
        [.nowPlaying]
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            switch controller.selectedTab {
            case .nowPlaying: nowPlayingTab
            }
        }
        .transition(.opacity)
    }

    // MARK: - Overview Tab (shows everything)

    private var nowPlayingTab: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 20) {
                    albumArtwork(size: 260, radius: 28)
                        .shadow(color: musicManager.accentColor.opacity(0.5), radius: 32, y: 16)

                    VStack(spacing: 6) {
                        Text(musicManager.title ?? String(localized: "Not Playing"))
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        Text(musicManager.artist ?? String(localized: "Unknown Artist"))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)

                        if let album = musicManager.album, !album.isEmpty, album != musicManager.title {
                            Text(album)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.3))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 440)

                    HStack(spacing: 8) {
                        if musicManager.totalDuration > 0 {
                            let mins = Int(musicManager.totalDuration) / 60
                            let secs = Int(musicManager.totalDuration) % 60
                            statPill(icon: "clock.fill", label: "Duration", value: String(format: "%d:%02d", mins, secs), color: .cyan)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 56)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Overview Helpers

    private func statPill(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Shared Views

    @ViewBuilder
    private func albumArtwork(size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let cover = musicManager.artwork ?? musicManager.appIcon {
                Image(nsImage: cover)
                    .resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.28, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    // MARK: - Background

    private var ambientBackground: some View {
        GeometryReader { geo in
            ZStack {
                (desktopWallpaper.map { AnyView(Image(nsImage: $0).resizable().aspectRatio(contentMode: .fill)) }
                    ?? AnyView(musicManager.accentColor))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 64, opaque: true)
                    .clipped()
                if let image = musicManager.artwork ?? musicManager.appIcon {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 48, opaque: true)
                        .saturation(1.35)
                        .opacity(0.45)
                }
                RadialGradient(
                    colors: [musicManager.leftGradientColor.opacity(0.72), musicManager.accentColor.opacity(0.42), musicManager.rightGradientColor.opacity(0.18), Color.black.opacity(0.55)],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height)
                )
                LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.42)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

// MARK: - Dock

private struct LockScreenMusicDock: View {
    @Binding var navigationStack: [NotchWidgetMode]
    @ObservedObject var navigationManager: LockScreenNavigationManager
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var musicManager: MusicManager
    var body: some View {
        MusicPlayerView(navigationStack: $navigationStack, isLockScreenMode: true, showArtworkSection: false)
            .environmentObject(navigationManager)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(musicManager.accentColor.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
            .frame(maxWidth: 600)
    }
}
