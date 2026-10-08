import Foundation
import XCTest
@testable import Sapphire

final class LocalizationFormattingTests: XCTestCase {
    // Run each locale in its own process with -testLanguage/-testRegion.
    private var isChinese: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }

    private let countCases: [(value: Int, playEnglish: String, playChinese: String, compactEnglish: String, compactChinese: String)] = [
        (0, "0", "0", "0", "0"),
        (1, "1", "1", "1", "1"),
        (999, "999", "999", "999", "999"),
        (1_000, "1K", "1000", "1K", "1000"),
        (1_499, "1.5K", "1499", "1.5K", "1499"),
        (1_500, "1.5K", "1500", "1.5K", "1500"),
        (9_999, "10K", "9999", "10K", "9999"),
        (10_000, "10K", "1万", "10K", "1万"),
        (12_345, "12K", "1.2万", "12.3K", "1.2万"),
        (123_456, "123K", "12万", "123.5K", "12.3万"),
        (999_999, "1M", "100万", "1M", "100万"),
        (1_000_000, "1M", "100万", "1M", "100万"),
        (1_250_000, "1.2M", "125万", "1.2M", "125万"),
        (100_000_000, "100M", "1亿", "100M", "1亿"),
        (1_000_000_000, "1B", "10亿", "1B", "10亿"),
        (1_250_000_000, "1.2B", "12亿", "1.2B", "12.5亿"),
    ]

    func testProcessUsesAnExpectedLanguageAndRegion() {
        print("LOCALIZATION_TEST_LOCALE \(Locale.current.identifier); languages=\(Locale.preferredLanguages)")
        let language = Locale.current.language.languageCode?.identifier ?? ""
        let region = Locale.current.region?.identifier ?? ""
        XCTAssertTrue(
            (language == "en" && region == "US") ||
                (language == "zh" && (region == "CN" || region == "US")),
            "Run formatting tests in en/US, zh-Hans/CN, or zh-Hans/US; got \(Locale.current.identifier)"
        )
    }

    @MainActor
    func testPlayCountUsesLocaleThresholdsAndItsOwnRounding() {
        for item in countCases {
            XCTAssertEqual(
                PlayCountFetcher.formatPlayCount(item.value),
                isChinese ? item.playChinese : item.playEnglish,
                "Play count \(item.value), locale \(Locale.current.identifier)"
            )
        }
    }

    func testCompactIntegerUsesLocaleThresholdsAndOneFractionDigit() {
        for item in countCases {
            XCTAssertEqual(
                item.value.compactFormatted,
                isChinese ? item.compactChinese : item.compactEnglish,
                "Compact integer \(item.value), locale \(Locale.current.identifier)"
            )
        }
    }

    func testWeekdayNamesKeepTheirStoredCalendarIdentifiers() {
        let days: [(id: Int, english: String, chinese: String)] = [
            (1, "Sun", "周日"), (2, "Mon", "周一"), (3, "Tue", "周二"),
            (4, "Wed", "周三"), (5, "Thu", "周四"), (6, "Fri", "周五"), (7, "Sat", "周六"),
        ]

        for day in days {
            var schedule = ScheduledFocusSession()
            schedule.repeatInterval = .custom
            schedule.repeatWeekdays = [day.id]

            XCTAssertEqual(schedule.repeatDescription, isChinese ? day.chinese : day.english)
            XCTAssertEqual(schedule.sortedDisplayWeekdays, [day.id])
            XCTAssertEqual(schedule.repeatWeekdays, [day.id])
            XCTAssertTrue(schedule.customRepeats(on: day.id))
        }
    }

    func testWeekdayListFormattingDoesNotReorderStoredDaysOrChangeMatching() {
        var schedule = ScheduledFocusSession()
        schedule.repeatInterval = .custom
        schedule.repeatWeekdays = [1, 7, 2]

        XCTAssertEqual(schedule.repeatDescription, isChinese ? "周一、周六和周日" : "Mon, Sat, and Sun")
        XCTAssertEqual(schedule.sortedDisplayWeekdays, [2, 7, 1])
        XCTAssertEqual(schedule.repeatWeekdays, [1, 7, 2])
        XCTAssertEqual(
            (1...7).map { schedule.customRepeats(on: $0) },
            [true, true, false, false, false, false, true]
        )
    }

    func testLocalizedScheduleStillEncodesRawRepeatAndWeekdayValues() throws {
        var schedule = ScheduledFocusSession()
        schedule.startTime = Date(timeIntervalSince1970: 1_700_000_000)
        schedule.repeatInterval = .custom
        schedule.repeatWeekdays = [1, 7, 2]
        _ = schedule.repeatDescription

        let data = try JSONEncoder().encode(schedule)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["repeatInterval"] as? String, "custom")
        XCTAssertEqual(json["repeatWeekdays"] as? [Int], [1, 7, 2])
        XCTAssertEqual(try JSONDecoder().decode(ScheduledFocusSession.self, from: data), schedule)
    }

    func testWeatherFormattingPreservesTheExplicitUnitInEitherLanguage() {
        XCTAssertEqual(
            WeatherDisplayFormatting.measurement(12.5, unit: UnitSpeed.milesPerHour, maximumFractionDigits: 1),
            isChinese ? "12.5英里/小时" : "12.5mph"
        )
        XCTAssertEqual(
            WeatherDisplayFormatting.measurement(12, unit: UnitSpeed.kilometersPerHour),
            isChinese ? "12公里/时" : "12km/h"
        )
        XCTAssertEqual(
            WeatherDisplayFormatting.measurement(29.92, unit: UnitPressure.inchesOfMercury, maximumFractionDigits: 2),
            isChinese ? "29.92英寸汞柱" : "29.92″ Hg"
        )
        XCTAssertEqual(
            WeatherDisplayFormatting.unavailable(unit: UnitLength.kilometers),
            isChinese ? "— 公里" : "— km"
        )
    }
}
