import XCTest
@testable import Sapphire

/// Settings saved before the third-party music integrations were removed still name
/// removed buttons, hold actions and notch menus. They must load without resetting the
/// preferences that were kept, and the retained player buttons keep their slots.
final class MusicSettingsMigrationTests: XCTestCase {
    private static let formerDefaultOrder = ["playlists", "devices", "like", "shuffle", "repeat"]

    // MARK: - Player button slots

    func testSavedButtonOrderKeepsRetainedButtonsInTheirFormerSlots() throws {
        struct Case {
            let order: [String]
            let flags: [String: Bool]
            let slots: [MusicPlayerButtonSlot]
            let retainedOrder: [MusicPlayerButtonType]
            let primary: [MusicPlayerButtonType?]
            let accessory: [MusicPlayerButtonType]
        }
        let cases = [
            // Former defaults: queue and devices beside the controls, like off.
            Case(order: Self.formerDefaultOrder, flags: [:],
                 slots: [.reserved, .reserved, .button, .button], retainedOrder: [.shuffle, .repeat],
                 primary: [nil, nil], accessory: [.shuffle, .repeat]),
            // Queue and devices switched off: shuffle and repeat were beside the controls.
            Case(order: Self.formerDefaultOrder,
                 flags: ["musicPlaylistsButtonEnabled": false, "musicDevicesButtonEnabled": false],
                 slots: [.button, .button], retainedOrder: [.shuffle, .repeat],
                 primary: [.shuffle, .repeat], accessory: []),
            // Reordered, like on.
            Case(order: ["playlists", "repeat", "devices", "like", "shuffle"],
                 flags: ["musicLikeButtonEnabled": true],
                 slots: [.reserved, .button, .reserved, .reserved, .button], retainedOrder: [.repeat, .shuffle],
                 primary: [nil, .repeat], accessory: [.shuffle]),
            // Queue off, like on.
            Case(order: ["shuffle", "playlists", "devices", "like", "repeat"],
                 flags: ["musicPlaylistsButtonEnabled": false, "musicLikeButtonEnabled": true],
                 slots: [.button, .reserved, .reserved, .button], retainedOrder: [.shuffle, .repeat],
                 primary: [.shuffle, nil], accessory: [.repeat]),
        ]

        for (index, testCase) in cases.enumerated() {
            var payload = try legacyPayload()
            payload["musicPlayerButtonOrder"] = testCase.order
            for (key, value) in testCase.flags { payload[key] = value }
            let restored = try decode(payload)

            XCTAssertEqual(restored.musicPlayerButtonSlots, testCase.slots, "case \(index)")
            XCTAssertEqual(restored.musicPlayerButtonOrder, testCase.retainedOrder, "case \(index)")
            let layout = MusicPlayerButtonLayout.resolve(
                slots: restored.musicPlayerButtonSlots,
                order: restored.musicPlayerButtonOrder,
                isEnabled: { _ in true }
            )
            XCTAssertEqual(layout.primary, testCase.primary, "case \(index)")
            XCTAssertEqual(layout.accessory, testCase.accessory, "case \(index)")

            // Once saved in the new format the slots load unchanged.
            let resaved = try SettingsPersistence.encoder.encode(restored)
            XCTAssertEqual(SettingsPersistence.decodeFromPayload(resaved)?.musicPlayerButtonSlots, testCase.slots, "case \(index)")
        }
    }

    func testNewSettingsLayOutButtonsLikeTheFormerDefaults() {
        let settings = Settings()
        XCTAssertEqual(settings.musicPlayerButtonOrder, [.shuffle, .repeat])
        let layout = MusicPlayerButtonLayout.resolve(
            slots: settings.musicPlayerButtonSlots,
            order: settings.musicPlayerButtonOrder,
            isEnabled: { _ in true }
        )
        XCTAssertEqual(layout.primary, [nil, nil], "Queue and devices sat beside the controls")
        XCTAssertEqual(layout.accessory, [.shuffle, .repeat])
    }

    func testDisabledButtonsGiveUpTheirSlotWhileReservedSlotsStayBlank() {
        let slots: [MusicPlayerButtonSlot] = [.button, .reserved, .button]
        let shuffleOff = MusicPlayerButtonLayout.resolve(slots: slots, order: [.shuffle, .repeat]) { $0 != .shuffle }
        XCTAssertEqual(shuffleOff.primary, [nil, .repeat])
        XCTAssertEqual(shuffleOff.accessory, [])

        let bothOff = MusicPlayerButtonLayout.resolve(slots: slots, order: [.shuffle, .repeat]) { _ in false }
        XCTAssertEqual(bothOff.primary, [nil, nil])
        XCTAssertEqual(bothOff.accessory, [])

        let reordered = MusicPlayerButtonLayout.resolve(slots: slots, order: [.repeat, .shuffle]) { _ in true }
        XCTAssertEqual(reordered.primary, [.repeat, nil], "Reordering moves buttons between button slots only")
        XCTAssertEqual(reordered.accessory, [.shuffle])

        let fewerSlots = MusicPlayerButtonLayout.resolve(slots: [.reserved], order: [.shuffle, .repeat]) { _ in true }
        XCTAssertEqual(fewerSlots.primary, [nil, .shuffle], "Buttons without a slot are appended")
        XCTAssertEqual(fewerSlots.accessory, [.repeat])
    }

    // MARK: - Hold actions

    func testRemovedHoldActionsBecomeNoAction() throws {
        var payload = try legacyPayload()
        payload["musicLongPressPrevious"] = "openQueue"
        payload["musicLongPressNext"] = "openDevices"
        payload["musicLongPressPlayPause"] = "like"
        payload["musicLongPressShuffle"] = "like"
        payload["musicLongPressRepeat"] = "openQueue"
        let restored = try decode(payload)

        XCTAssertEqual(restored.musicLongPressPrevious, MusicLongPressAction.none)
        XCTAssertEqual(restored.musicLongPressNext, MusicLongPressAction.none)
        XCTAssertEqual(restored.musicLongPressPlayPause, MusicLongPressAction.none)
        XCTAssertEqual(restored.musicLongPressShuffle, MusicLongPressAction.none, "Not the .repeatMode default")
        XCTAssertEqual(restored.musicLongPressRepeat, MusicLongPressAction.none)
    }

    func testRetainedHoldActionsSurviveNextToRemovedOnes() throws {
        var payload = try legacyPayload()
        payload["musicLongPressPrevious"] = "seek"
        payload["musicLongPressNext"] = "openDevices"
        payload["musicLongPressShuffle"] = "playPause"
        payload["musicLongPressRepeat"] = "shuffle"
        let restored = try decode(payload)

        XCTAssertEqual(restored.musicLongPressPrevious, .seek)
        XCTAssertEqual(restored.musicLongPressNext, MusicLongPressAction.none)
        XCTAssertEqual(restored.musicLongPressShuffle, .playPause)
        XCTAssertEqual(restored.musicLongPressRepeat, .shuffle)
    }

    // MARK: - Notch navigation

    func testRemovedMusicMenusAreDroppedFromTheSavedNavigationStack() throws {
        let stack = ["defaultWidgets", "musicQueueAndPlaylists", "musicPlayer", "musicDevices"]
        var payload = try legacyPayload()
        payload["lastNotchNavigationStack"] = stack
        XCTAssertEqual(try decode(payload).lastNotchNavigationStack, [.defaultWidgets, .musicPlayer])

        let runtimeData = try JSONSerialization.data(withJSONObject: stack)
        XCTAssertEqual(SettingsPersistence.decodeNotchNavigationStack(runtimeData), [.defaultWidgets, .musicPlayer])
    }

    // MARK: - Unrelated preferences

    func testRetainedPreferencesSurviveRemovedMusicKeys() throws {
        for enabled in [false, true] {
            var settings = Settings()
            settings.musicShuffleButtonEnabled = enabled
            settings.musicRepeatButtonEnabled = !enabled
            settings.persistMusicWidgetWhenPaused = enabled
            settings.musicLongPressActionsEnabled = enabled
            settings.mediaSource = .appleMusic
            settings.musicWidgetEnabled = enabled
            var payload = try legacyPayload(from: settings)
            payload["showLyricsInLiveActivity"] = true
            payload["spotifyShowNextSong"] = true
            payload["showSpotifyVolumeHUD"] = true
            payload["musicLongPressLike"] = "shuffle"
            let restored = try decode(payload)

            XCTAssertEqual(restored.musicShuffleButtonEnabled, enabled)
            XCTAssertEqual(restored.musicRepeatButtonEnabled, !enabled)
            XCTAssertEqual(restored.persistMusicWidgetWhenPaused, enabled)
            XCTAssertEqual(restored.musicLongPressActionsEnabled, enabled)
            XCTAssertEqual(restored.musicWidgetEnabled, enabled)
            XCTAssertEqual(restored.mediaSource, .appleMusic)
            var normalized = settings
            normalized.normalizeCollectionOrders()
            XCTAssertEqual(restored.widgetOrder, normalized.widgetOrder)
        }
    }

    // MARK: - Settings stored one key per default

    @MainActor
    func testSplitKeyUserDefaultsKeepTheFormerSlotsAndHoldActions() throws {
        let suiteName = "MusicSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["shuffle", "playlists", "devices", "like", "repeat"], forKey: "musicPlayerButtonOrder")
        defaults.set(false, forKey: "musicPlaylistsButtonEnabled")
        defaults.set(true, forKey: "musicLikeButtonEnabled")
        defaults.set(true, forKey: "musicShuffleButtonEnabled")
        defaults.set("like", forKey: "musicLongPressRepeat")
        defaults.set("playPause", forKey: "musicLongPressShuffle")

        let restored = try XCTUnwrap(SettingsModel.decodeSettingsFromUserDefaults(defaults))

        XCTAssertEqual(restored.musicPlayerButtonOrder, [.shuffle, .repeat])
        XCTAssertEqual(restored.musicPlayerButtonSlots, [.button, .reserved, .reserved, .button])
        XCTAssertTrue(restored.musicShuffleButtonEnabled)
        XCTAssertEqual(restored.musicLongPressRepeat, MusicLongPressAction.none)
        XCTAssertEqual(restored.musicLongPressShuffle, .playPause)
    }

    // MARK: - Helpers

    /// A payload as the previous release saved it: the removed fields are present and
    /// the slot field that replaced them is not.
    private func legacyPayload(from settings: Settings = Settings()) throws -> [String: Any] {
        let data = try SettingsPersistence.encoder.encode(settings)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "musicPlayerButtonSlots")
        payload["musicPlayerButtonOrder"] = Self.formerDefaultOrder
        payload["musicPlaylistsButtonEnabled"] = true
        payload["musicDevicesButtonEnabled"] = true
        payload["musicLikeButtonEnabled"] = false
        return payload
    }

    private func decode(_ payload: [String: Any]) throws -> Settings {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(SettingsPersistence.decodeFromPayload(data))
    }
}
