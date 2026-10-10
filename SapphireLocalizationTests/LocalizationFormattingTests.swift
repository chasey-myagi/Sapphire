import Foundation
import XCTest
@testable import Sapphire

final class LocalizationFormattingTests: XCTestCase {
    // Run each locale in its own process with -testLanguage/-testRegion.
    private var isChinese: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }

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
