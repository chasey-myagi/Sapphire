import Foundation
import XCTest
@testable import Sapphire

final class LocalizationFormattingTests: XCTestCase {
    // Run each locale in its own process with -testLanguage/-testRegion.
    private var isChinese: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }

    private var isTraditionalChinese: Bool {
        isChinese && (Locale.preferredLanguages.first ?? "").hasPrefix("zh-Hant")
    }

    /// Expected text for the language this test process runs in.
    private func expected(_ english: String, _ simplified: String, _ traditional: String) -> String {
        isTraditionalChinese ? traditional : isChinese ? simplified : english
    }

    func testProcessUsesAnExpectedLanguageAndRegion() {
        print("LOCALIZATION_TEST_LOCALE \(Locale.current.identifier); languages=\(Locale.preferredLanguages)")
        let language = Locale.current.language.languageCode?.identifier ?? ""
        let region = Locale.current.region?.identifier ?? ""
        XCTAssertTrue(
            (language == "en" && region == "US") ||
                (language == "zh" && !isTraditionalChinese && (region == "CN" || region == "US")) ||
                (isTraditionalChinese && region == "TW"),
            "Run formatting tests in en/US, zh-Hans/CN, zh-Hans/US, or zh-Hant/TW; got \(Locale.current.identifier)"
        )
    }

    func testWeekdayNamesKeepTheirStoredCalendarIdentifiers() {
        let days: [(id: Int, english: String, simplified: String, traditional: String)] = [
            (1, "Sun", "周日", "週日"), (2, "Mon", "周一", "週一"), (3, "Tue", "周二", "週二"),
            (4, "Wed", "周三", "週三"), (5, "Thu", "周四", "週四"), (6, "Fri", "周五", "週五"), (7, "Sat", "周六", "週六"),
        ]

        for day in days {
            var schedule = ScheduledFocusSession()
            schedule.repeatInterval = .custom
            schedule.repeatWeekdays = [day.id]

            XCTAssertEqual(schedule.repeatDescription, expected(day.english, day.simplified, day.traditional))
            XCTAssertEqual(schedule.sortedDisplayWeekdays, [day.id])
            XCTAssertEqual(schedule.repeatWeekdays, [day.id])
            XCTAssertTrue(schedule.customRepeats(on: day.id))
        }
    }

    func testWeekdayListFormattingDoesNotReorderStoredDaysOrChangeMatching() {
        var schedule = ScheduledFocusSession()
        schedule.repeatInterval = .custom
        schedule.repeatWeekdays = [1, 7, 2]

        XCTAssertEqual(schedule.repeatDescription, expected("Mon, Sat, and Sun", "周一、周六和周日", "週一、週六和週日"))
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
            expected("12.5mph", "12.5英里/小时", "12.5英里/小時")
        )
        XCTAssertEqual(
            WeatherDisplayFormatting.measurement(12, unit: UnitSpeed.kilometersPerHour),
            expected("12km/h", "12公里/时", "12公里/小時")
        )
        XCTAssertEqual(
            WeatherDisplayFormatting.measurement(29.92, unit: UnitPressure.inchesOfMercury, maximumFractionDigits: 2),
            expected("29.92″ Hg", "29.92英寸汞柱", "29.92英吋汞柱")
        )
        XCTAssertEqual(
            WeatherDisplayFormatting.unavailable(unit: UnitLength.kilometers),
            isChinese ? "— 公里" : "— km"
        )
    }
}
