//
//  WidgetLayoutPolicy.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-08-10

import AppKit

enum WidgetLayoutPolicy {
    static func enabledWidgets(
        settings: Settings,
        isMusicPlaying: Bool,
        isSpotifyPausedWithNoOtherPlayback: Bool
    ) -> [WidgetType] {
        return settings.widgetOrder.filter { widgetType in
            #if !SAPPHIRE_FULL_BUILD
            // Public placeholders have no widget content; retain saved preferences.
            if widgetType == .sports || widgetType == .storage { return false }
            #endif
            switch widgetType {
            case .music:
                return MusicWidgetVisibilityPolicy.shouldShow(
                    isEnabled: settings.musicWidgetEnabled,
                    hideWhenNotPlaying: settings.hideMusicWidgetWhenNotPlaying,
                    isPlaying: isMusicPlaying,
                    hidePausedSpotifyWhenIdle: settings.hideMusicWidgetWhenSpotifyPausedAndIdle,
                    isSpotifyPausedWithNoOtherPlayback: isSpotifyPausedWithNoOtherPlayback
                )
            case .weather:
                return settings.weatherWidgetEnabled
            case .sports:
                return settings.sportsWidgetEnabled
            case .calendar:
                return settings.calendarWidgetEnabled
            case .battery:
                return settings.batteryWidgetEnabled
            case .timer:
                return settings.timerWidgetEnabled
            case .shortcuts:
                return settings.shortcutsWidgetEnabled
            case .notes:
                return settings.notesWidgetEnabled
            case .clipboard:
                return settings.clipboardWidgetEnabled
            case .mirror:
                return settings.mirrorWidgetEnabled
            case .storage:
                return settings.storageWidgetEnabled
            case .focusSession:
                return settings.focusSessionWidgetEnabled
            }
        }
    }

    static let interWidgetSpacing: CGFloat = 20
    static let dividerWidth: CGFloat = 1

    static func estimatedWidth(for widget: WidgetType) -> CGFloat {
        switch widget {
        case .music: return 300
        case .weather: return 210
        case .calendar: return 240
        case .shortcuts: return 110
        case .sports: return 190
        case .notes: return 176
        case .clipboard: return 176
        case .mirror: return 140
        case .battery: return 210
        case .timer: return 150
        case .focusSession: return 190
        case .storage: return 210
        }
    }

    static func expandedWidthLimit(screenWidth: CGFloat) -> CGFloat {
        min(720, max(1, screenWidth - 48))
    }

    static func availableBarWidth(for screen: NSScreen? = nil) -> CGFloat {
        expandedWidthLimit(screenWidth: (screen ?? NSScreen.main)?.frame.width ?? 1440)
    }

    static func boundedExpandedWidth(contentWidth: CGFloat, minimumWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        min(expandedWidthLimit(screenWidth: screenWidth), max(1, contentWidth, minimumWidth))
    }

    static func totalWidth(for widgets: [WidgetType], showDividers: Bool) -> CGFloat {
        guard !widgets.isEmpty else { return 0 }
        var total = widgets.reduce(0) { $0 + estimatedWidth(for: $1) }
        if widgets.count > 1 {
            total += interWidgetSpacing * CGFloat(widgets.count - 1)
            if showDividers {
                total += (interWidgetSpacing + dividerWidth) * CGFloat(widgets.count - 1)
            }
        }
        return total
    }

}
