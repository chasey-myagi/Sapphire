import XCTest
@testable import Sapphire

final class LocalizationNavigationTests: XCTestCase {
    func testPreferredUpdateChannelPreservesTheUsersChoice() {
        var settings = Settings()
        settings.releaseChannel = .beta
        XCTAssertEqual(ReleaseChannelPolicy.preferredChannel(from: settings), .beta)
        settings.releaseChannel = .stable
        XCTAssertEqual(ReleaseChannelPolicy.preferredChannel(from: settings), .stable)
    }

    @MainActor
    func testTextConversionOffersSupportedDocumentFormatsWithoutAnAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("document.txt")
        try Data("Sample document".utf8).write(to: document)
        let formats = Set(FileConversionManager.shared.availableFormats(for: document).map(\.id))
        XCTAssertTrue(formats.contains("pdf"))
        XCTAssertTrue(formats.contains("rtf"))
        XCTAssertFalse(formats.contains("txt"), "Do not offer conversion to the existing format")
        XCTAssertTrue(FileConversionManager.shared.availableFormats(for: directory.appendingPathComponent("missing.txt")).isEmpty)
    }

    func testSavedFeatureSwitchesSurviveProductionPayloadDecoding() throws {
        for enabled in [false, true] {
            var settings = Settings()
            settings.sportsWidgetEnabled = enabled
            settings.storageWidgetEnabled = enabled
            settings.sportsLiveActivityEnabled = enabled
            settings.menuBarProfilesEnabled = enabled
            settings.devActivityEnabled = enabled
            let payload = try SettingsPersistence.encoder.encode(settings)
            let restored = try XCTUnwrap(SettingsPersistence.decodeFromPayload(payload))
            XCTAssertEqual(restored.sportsWidgetEnabled, enabled)
            XCTAssertEqual(restored.storageWidgetEnabled, enabled)
            XCTAssertEqual(restored.sportsLiveActivityEnabled, enabled)
            XCTAssertEqual(restored.menuBarProfilesEnabled, enabled)
            XCTAssertEqual(restored.devActivityEnabled, enabled)
        }
        XCTAssertFalse(Settings().devActivityEnabled)
    }

    func testUnknownOrderedIdentifiersPreserveRetainedOrderAndPreferences() throws {
        for enabled in [false, true] {
            var settings = Settings()
            settings.sportsWidgetEnabled = enabled
            settings.storageWidgetEnabled = enabled
            settings.sportsLiveActivityEnabled = enabled
            settings.menuBarProfilesEnabled = enabled
            settings.devActivityEnabled = enabled
            let data = try SettingsPersistence.encoder.encode(settings)
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            payload["widgetOrder"] = ["notes", "finance", "shopify", "agent", "unknownWidget", "music", "sports"]
            payload["liveActivityOrder"] = ["devActivity", "finance", "unknownActivity", "sports", "music"]
            payload["notchButtonOrder"] = ["pin", "intelligence", "intelligenceLive", "unknownButton", "notes", "settings"]
            payload["lastNotchNavigationStack"] = ["defaultWidgets", "financePlayer", "unknownMenu", "musicPlayer", "sportsPlayer"]
            let restored = try XCTUnwrap(SettingsPersistence.decodeFromPayload(try JSONSerialization.data(withJSONObject: payload)))
            XCTAssertEqual(Array(restored.widgetOrder.prefix(3)), [.notes, .music, .sports])
            XCTAssertEqual(Array(restored.liveActivityOrder.prefix(3)), [.devActivity, .sports, .music])
            XCTAssertEqual(Array(restored.notchButtonOrder.prefix(3)), [.pin, .notes, .settings])
            XCTAssertEqual(restored.lastNotchNavigationStack, [.defaultWidgets, .musicPlayer, .sportsPlayer])
            XCTAssertEqual(SettingsPersistence.decodeNotchNavigationStack(Data("[\"defaultWidgets\",\"financePlayer\",\"unknownMenu\",\"musicPlayer\"]".utf8)), [.defaultWidgets, .musicPlayer])
            XCTAssertEqual(restored.sportsWidgetEnabled, enabled)
            XCTAssertEqual(restored.storageWidgetEnabled, enabled)
            XCTAssertEqual(restored.sportsLiveActivityEnabled, enabled)
            XCTAssertEqual(restored.menuBarProfilesEnabled, enabled)
            XCTAssertEqual(restored.devActivityEnabled, enabled)
        }
        XCTAssertFalse(Settings().devActivityEnabled)
    }

    func testChineseAndEnglishNamesFindTheSameSettingsPages() {
        for (query, expected) in [("音乐", SettingsSection.music), ("Music", .music), ("电池", .battery), ("Battery", .battery), ("文件", .fileShelf), ("File Shelf", .fileShelf), ("音樂", .music), ("電池", .battery), ("檔案", .fileShelf)] {
            XCTAssertTrue(SettingsSection.sidebarGroups(matching: query).flatMap(\.sections).contains(expected), query)
        }
    }

    func testSearchTrimsWhitespaceAndIgnoresEnglishCase() {
        XCTAssertEqual(SettingsSection.sidebarGroups(matching: "  mUsIc \n").flatMap(\.sections), SettingsSection.sidebarGroups(matching: "music").flatMap(\.sections))
        XCTAssertEqual(SettingsSection.sidebarGroups(matching: " \n").map(\.id), SettingsSection.sidebarGroups.map(\.id))
        XCTAssertTrue(SettingsSection.sidebarGroups(matching: "a-setting-that-does-not-exist").isEmpty)
    }

    func testSidebarGroupIdentityIsIndependentOfItsDisplayTitle() {
        let expectedIDs = ["general", "notch", "widgetsAndContent", "systemAndUtilities", "focusAndSecurity", "about"]
        XCTAssertEqual(SettingsSection.sidebarGroups.map(\.id), expectedIDs)
        for group in SettingsSection.sidebarGroups {
            let translated = SettingsSidebarGroup(id: group.id, title: "已翻译的标题", sections: group.sections)
            XCTAssertEqual(translated.id, group.id)
        }
        XCTAssertEqual(SettingsSection.sidebarGroups(matching: "音乐").map(\.id), ["widgetsAndContent"])
    }

    func testSidebarHasEverySectionExactlyOnce() {
        let sections = SettingsSection.sidebarGroups.flatMap(\.sections)
        XCTAssertEqual(sections.count, SettingsSection.allCases.count)
        XCTAssertEqual(Set(sections), Set(SettingsSection.allCases))
    }

    func testSavedIdentifiersStillDecodeWithoutUsingDisplayNames() throws {
        XCTAssertEqual(SettingsSection(rawValue: "fileShelf"), .fileShelf)
        XCTAssertEqual(SettingsSection(rawValue: "keyboardShortcuts"), .keyboardShortcuts)
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(WidgetSwitchEffect.self, from: Data("\"bouncy\"".utf8)), .bouncy)
        XCTAssertEqual(try decoder.decode(SnapZoneViewMode.self, from: Data("\"multi\"".utf8)), .multi)
        XCTAssertEqual(try decoder.decode(NotchBackgroundStyle.self, from: Data("\"radial\"".utf8)), .radial)
    }
}
