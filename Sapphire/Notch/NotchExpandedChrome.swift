//
//  NotchExpandedChrome.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-09-02

import SwiftUI
import AppKit

enum NotchToolbarMetrics {
    static let gearWidth: CGFloat = 32
    static let gearSpacing: CGFloat = 8
    static let minimumWingWidth: CGFloat = 80
}

struct NotchToolbarLayout<Gear: View, Left: View, Right: View>: View {
    let width: CGFloat
    let height: CGFloat
    let horizontalPadding: CGFloat
    let cutoutWidth: CGFloat
    @Binding var isScrollHovered: Bool
    let gear: Gear
    let left: Left
    let right: Right
    @State private var isLeftHovered = false
    @State private var isRightHovered = false

    var body: some View {
        let padding = min(horizontalPadding, max(0, (width - cutoutWidth) / 2 - NotchToolbarMetrics.minimumWingWidth))
        let wingWidth = max(1, (width - cutoutWidth - 2 * padding) / 2)
        HStack(spacing: 0) {
            HStack(spacing: NotchToolbarMetrics.gearSpacing) {
                gear.frame(width: NotchToolbarMetrics.gearWidth)
                ScrollView(.horizontal) { left }
                    .frame(width: max(1, wingWidth - NotchToolbarMetrics.gearWidth - NotchToolbarMetrics.gearSpacing))
                    .onHover { isLeftHovered = $0 }
            }
            .frame(width: wingWidth)
            Color.clear.frame(width: cutoutWidth)
            ScrollView(.horizontal) { right }
                .frame(width: wingWidth)
                .onHover { isRightHovered = $0 }
        }
        .padding(.horizontal, padding)
        .frame(width: width, height: height)
        .onChange(of: isLeftHovered || isRightHovered) { _, hovered in
            isScrollHovered = hovered
        }
        .onDisappear {
            isLeftHovered = false
            isRightHovered = false
            isScrollHovered = false
        }
    }
}

struct NotchExpandedChrome: View {
    let config: ResolvedNotchConfiguration
    let mode: NotchWidgetMode
    let notchState: NotchController.NotchState
    let animatedWidth: CGFloat
    let showRightHUDOverlay: Bool
    let cutoutWidth: CGFloat
    @Binding var isScrollHovered: Bool
    @Binding var navigationStack: [NotchWidgetMode]
    @Binding var isPinned: Bool
    @Binding var iconsLeftWidth: CGFloat
    @Binding var iconsRightWidth: CGFloat
    let onPin: (Bool) -> Void

    @EnvironmentObject private var settings: SettingsModel
    @ObservedObject private var caffeineManager = CaffeineManager.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if mode == .defaultWidgets {
                defaultModeIcons
            } else if ![.fileShelfLanding, .snapZones, .dragActivated].contains(mode) {
                navigationHeader
            }
        }

    }

    private var currentViewTitle: String? {
        switch mode {
        case .multiAudioDeviceAdjust: return String(localized: "Adjust")
        case .multiAudioEQ: return String(localized: "EQ")
        case .musicDevices: return String(localized: "Devices")
        case .musicQueueAndPlaylists: return String(localized: "Queue & Playlists")
        case .multiAudio: return String(localized: "Audio Devices")
        default: return nil
        }
    }

    private var leftNotchButtons: [NotchButtonType] {
        let allButtons = settings.settings.notchButtonOrder
        if let spacerIndex = allButtons.firstIndex(of: .spacer) {
            return Array(allButtons.prefix(upTo: spacerIndex))
        }
        return allButtons
    }

    private var rightNotchButtons: [NotchButtonType] {
        let allButtons = settings.settings.notchButtonOrder
        if let spacerIndex = allButtons.firstIndex(of: .spacer) {
            return Array(allButtons.suffix(from: allButtons.index(after: spacerIndex)))
        }
        return []
    }

    @ViewBuilder
    private var navigationHeader: some View {
        ZStack {
            HStack {
                Button(action: {
                    if NotchBackRouter.shared.handleBack() { return }
                    if navigationStack.count > 1 {
                        navigationStack.removeLast()
                    } else {
                        navigationStack = [.defaultWidgets]
                    }
                }) {
                    NotchCapsuleBackButtonContent()
                        .padding(.leading, config.navHeaderLeadingPadding + 10)
                }
                .padding(.top, config.navHeaderTopPadding)
                .buttonStyle(.plain)

                NotchMediaSourceSwitcherSlot(
                    mode: mode,
                    topPadding: config.navHeaderTopPadding
                )

                if let title = currentViewTitle {
                    Text(title)
                        .font(.system(size: config.navHeaderTitleFontSize, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.top, config.navHeaderTitleTopPadding)
                }
                Spacer()
            }
        }
        .frame(height: config.initialSize.height)
        .frame(width: animatedWidth)
    }

    @ViewBuilder
    private var defaultModeIcons: some View {
        NotchToolbarLayout(
            width: animatedWidth,
            height: config.initialSize.height,
            horizontalPadding: config.defaultModeIconsHorizontalPadding,
            cutoutWidth: cutoutWidth,
            isScrollHovered: $isScrollHovered,
            gear: notchButton(for: .settings),
            left: HStack(spacing: 0) {
                ForEach(leftNotchButtons.filter { $0 != .settings }) { buttonType in
                    notchButton(for: buttonType)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .measureIdealWidth(into: $iconsLeftWidth),
            right: HStack(spacing: 0) {
                ForEach(rightNotchButtons.filter { $0 != .settings }) { buttonType in
                    notchButton(for: buttonType)
                }
            }
            .opacity(showRightHUDOverlay ? 0.0 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: showRightHUDOverlay)
            .fixedSize(horizontal: true, vertical: false)
            .measureIdealWidth(into: $iconsRightWidth)
        )
    }

    @ViewBuilder
    private func notchButton(for type: NotchButtonType) -> some View {
        switch type {
        case .settings:
            SubtleIconButton(systemName: "gearshape", action: {
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            })
        case .fileShelf:
            if settings.settings.fileShelfIconEnabled {
                SubtleIconButton(systemName: "tray.full", action: { navigationStack.append(.fileShelf) })
            }
        case .notes:
            if settings.settings.notesIconEnabled {
                SubtleIconButton(systemName: "note.text", action: { navigationStack.append(.notesPlayer) })
            }
        case .clipboard:
            if settings.settings.clipboardIconEnabled {
                SubtleIconButton(systemName: "list.clipboard", action: { navigationStack.append(.clipboardPlayer) })
            }
        case .focusSession:
            if settings.settings.focusSessionIconEnabled {
                SubtleIconButton(
                    systemName: "moon.fill",
                    action: { navigationStack.append(.focusSessionDetailView) }
                )
            }
        case .caffeine:
            if settings.settings.caffeinateEnabled {
                SubtleIconButton(systemName: caffeineManager.isActive ? "cup.and.heat.waves.fill" : "cup.and.heat.waves", action: { caffeineManager.toggle() }, horizontalPadding: 6)
                    .offset(y: -2)
            }
        case .battery:
            if settings.settings.batteryEstimatorEnabled {
                NotchBatteryInfoSlot()
            } else {
                EmptyView()
            }
        case .multiAudio:
            if settings.settings.showMultiAudioIcon {
                SubtleIconButton(systemName: "hifispeaker.and.homepod.mini.fill", action: { navigationStack.append(.multiAudio) })
            }
        case .pin:
            if settings.settings.pinEnabled {
                SubtleIconButton(systemName: isPinned ? "pin.fill" : "pin", action: {
                    isPinned.toggle()
                    onPin(isPinned)
                }, horizontalPadding: 6)
            }
        case .spacer:
            EmptyView()
        }
    }
}

private struct NotchMediaSourceSwitcherSlot: View {
    @EnvironmentObject private var musicManager: MusicManager

    let mode: NotchWidgetMode
    let topPadding: CGFloat

    var body: some View {
        if mode == .musicPlayer, musicManager.activeMediaSources.count > 1 {
            NotchMediaSourceSwitcher()
                .padding(.top, topPadding)
                .padding(.leading, 6)
        }
    }
}

private struct NotchBatteryInfoSlot: View {
    @EnvironmentObject private var batteryEstimator: BatteryEstimator

    var body: some View {
        BatteryInfoView(
            level: batteryEstimator.batteryLevel,
            isCharging: batteryEstimator.isCharging,
            timeRemaining: batteryEstimator.estimatedTimeRemaining
        )
        .padding(.horizontal, NotchConfiguration.batteryHorizontalPadding)
    }
}
