//
//  MusicWidgetVisibilityTests.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2026-09-14

import XCTest
@testable import Sapphire

final class MusicWidgetVisibilityTests: XCTestCase {
    func testHideWhenNotPlayingUsesPlaybackInsteadOfCachedTrackMetadata() {
        XCTAssertFalse(MusicWidgetVisibilityPolicy.shouldShow(
            isEnabled: true,
            hideWhenNotPlaying: true,
            isPlaying: false,
            hidePausedSpotifyWhenIdle: false,
            isSpotifyPausedWithNoOtherPlayback: false
        ))

        XCTAssertTrue(MusicWidgetVisibilityPolicy.shouldShow(
            isEnabled: true,
            hideWhenNotPlaying: true,
            isPlaying: true,
            hidePausedSpotifyWhenIdle: false,
            isSpotifyPausedWithNoOtherPlayback: false
        ))
    }

    func testPausedSpotifyRuleCanHideWithoutGeneralPlaybackRule() {
        XCTAssertFalse(MusicWidgetVisibilityPolicy.shouldShow(
            isEnabled: true,
            hideWhenNotPlaying: false,
            isPlaying: false,
            hidePausedSpotifyWhenIdle: true,
            isSpotifyPausedWithNoOtherPlayback: true
        ))
    }

    func testDisabledWidgetNeverShows() {
        XCTAssertFalse(MusicWidgetVisibilityPolicy.shouldShow(
            isEnabled: false,
            hideWhenNotPlaying: false,
            isPlaying: true,
            hidePausedSpotifyWhenIdle: false,
            isSpotifyPausedWithNoOtherPlayback: false
        ))
    }

    func testEnabledWidgetsRemainInOrderWhenStripOverflows() {
        var settings = Settings()
        settings.widgetOrder = [.weather, .calendar, .shortcuts, .music]
        settings.weatherWidgetEnabled = true
        settings.calendarWidgetEnabled = true
        settings.shortcutsWidgetEnabled = true
        settings.musicWidgetEnabled = true
        XCTAssertEqual(WidgetLayoutPolicy.enabledWidgets(settings: settings, isMusicPlaying: true, isSpotifyPausedWithNoOtherPlayback: false), settings.widgetOrder)
        XCTAssertGreaterThan(WidgetLayoutPolicy.totalWidth(for: settings.widgetOrder, showDividers: false), 720)
    }

    func testMusicConsumesItsActualInitialViewportWidth() {
        XCTAssertEqual(WidgetLayoutPolicy.estimatedWidth(for: .music), 300)
    }

    func testSpaceLimitBypassIsDisabledByDefault() {
        XCTAssertFalse(Settings().bypassWidgetSpaceLimit)
    }

}
