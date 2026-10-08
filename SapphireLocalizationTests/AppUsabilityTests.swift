import XCTest
import UserNotifications
@testable import Sapphire

final class AppUsabilityTests: XCTestCase {
    private func withLanguageStore(_ body: (UserDefaults, String, AppLanguagePreferenceStore) throws -> Void) throws {
        let domain = "SapphireTests.AppLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults, domain, AppLanguagePreferenceStore(defaults: defaults, domainName: domain))
    }

    func testMissingAppOverrideFollowsSystemDespiteInheritedLanguages() throws {
        try withLanguageStore { defaults, domain, store in
            let fallbackDomain = domain + ".fallback"
            let fallback = try XCTUnwrap(UserDefaults(suiteName: fallbackDomain))
            fallback.set(["zh-Hans"], forKey: "AppleLanguages")
            defaults.addSuite(named: fallbackDomain)
            defer {
                defaults.removeSuite(named: fallbackDomain)
                fallback.removePersistentDomain(forName: fallbackDomain)
            }
            // A lookup can inherit a language from another domain or launch arguments.
            XCTAssertNotNil(defaults.array(forKey: "AppleLanguages"))
            XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
            XCTAssertEqual(store.selection, .followSystem)
            XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
        }
    }

    func testExplicitLanguageChoicesUseNativeAppOverrides() throws {
        try withLanguageStore { defaults, domain, store in
            for (choice, code) in [(AppLanguagePreference.english, "en"), (.simplifiedChinese, "zh-Hans")] {
                store.select(choice)
                XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], [code])
                XCTAssertEqual(store.selection, choice)
            }
        }
    }

    func testFollowSystemRemovesOnlyTheAppLanguageKey() throws {
        try withLanguageStore { defaults, domain, store in
            let preserved: [String: Any] = ["AppleLocale": "zh_CN", "savedSettings": Data([1, 2, 3]), "unrelated": true]
            var saved = preserved
            saved["AppleLanguages"] = ["en"]
            defaults.setPersistentDomain(saved, forName: domain)
            store.select(.followSystem)
            XCTAssertEqual(store.selection, .followSystem)
            XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: domain))), NSDictionary(dictionary: preserved))
        }
    }

    func testUnknownOverridesAreNotSilentlyReplaced() throws {
        try withLanguageStore { defaults, domain, store in
            for override in [["fr"], ["en", "zh-Hans"], [String]()] {
                let saved: [String: Any] = ["AppleLanguages": override, "unrelated": "keep"]
                defaults.setPersistentDomain(saved, forName: domain)
                XCTAssertEqual(store.selection, .existingOverride)
                store.select(.existingOverride)
                XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: domain))), NSDictionary(dictionary: saved))
            }
            store.select(.english)
            XCTAssertEqual(store.selection, .english)
            XCTAssertEqual(defaults.persistentDomain(forName: domain)?["unrelated"] as? String, "keep")
        }
    }

    func testFullDiskAccessAlwaysOffersSettingsUntilGranted() {
        XCTAssertEqual(PermissionActionPolicy.action(for: .fullDiskAccess, status: .notRequested), .openSettings(.allFiles))
        XCTAssertEqual(PermissionActionPolicy.action(for: .fullDiskAccess, status: .denied), .openSettings(.allFiles))
        XCTAssertNil(PermissionActionPolicy.action(for: .fullDiskAccess, status: .granted))
    }

    func testNotificationsRequestOnceAndRecoverThroughSettingsAfterDenial() {
        XCTAssertEqual(PermissionActionPolicy.action(for: .notifications, status: .notRequested), .request)
        XCTAssertEqual(PermissionActionPolicy.action(for: .notifications, status: .denied), .openSettings(.notifications))
        XCTAssertNil(PermissionActionPolicy.action(for: .notifications, status: .granted))
    }

    func testOtherPermissionActionsKeepTheirExistingBehavior() {
        for type in PermissionType.allCases where type != .fullDiskAccess && type != .notifications {
            XCTAssertEqual(PermissionActionPolicy.action(for: type, status: .notRequested), .request)
            XCTAssertNil(PermissionActionPolicy.action(for: type, status: .denied))
            XCTAssertNil(PermissionActionPolicy.action(for: type, status: .granted))
        }
    }

    func testNotificationRefreshMapsActualAuthorizationStates() {
        XCTAssertEqual(PermissionActionPolicy.notificationStatus(for: .notDetermined), .notRequested)
        XCTAssertEqual(PermissionActionPolicy.notificationStatus(for: .denied), .denied)
        XCTAssertEqual(PermissionActionPolicy.notificationStatus(for: .authorized), .granted)
        XCTAssertEqual(PermissionActionPolicy.notificationStatus(for: .provisional), .granted)
    }

    func testDeniedNotificationsLinkTargetsNotificationsSettings() {
        XCTAssertEqual(SystemPreferencesPane.notifications.url.absoluteString, "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    func testExistingFullDiskAccessLinkTargetsItsSystemPane() {
        XCTAssertEqual(SystemPreferencesPane.allFiles.url.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
