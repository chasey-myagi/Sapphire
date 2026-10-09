import AppKit
import SwiftUI

// Only data and application routing boundaries are replaced. The probe compiles
// the production layout policy and WeatherWidgetView unchanged.
enum WidgetType: String { case music, weather, calendar, shortcuts, sports, notes, clipboard, mirror, battery, timer, focusSession, storage }
struct Settings {
    var widgetOrder: [WidgetType] = []
    var musicWidgetEnabled = true, hideMusicWidgetWhenNotPlaying = false
    var hideMusicWidgetWhenSpotifyPausedAndIdle = false
    var weatherWidgetEnabled = true, sportsWidgetEnabled = false, calendarWidgetEnabled = true
    var batteryWidgetEnabled = true, timerWidgetEnabled = false, shortcutsWidgetEnabled = false
    var notesWidgetEnabled = false, clipboardWidgetEnabled = false, mirrorWidgetEnabled = false
    var storageWidgetEnabled = false, focusSessionWidgetEnabled = true
}
enum MusicWidgetVisibilityPolicy {
    static func shouldShow(isEnabled: Bool, hideWhenNotPlaying: Bool, isPlaying: Bool, hidePausedSpotifyWhenIdle: Bool, isSpotifyPausedWithNoOtherPlayback: Bool) -> Bool { isEnabled }
}
enum CursorPosition { static func targetNotchScreen() -> NSScreen? { nil } }
enum NotchConfiguration {
    static func screenWidthAdjustment(for screen: NSScreen?) -> CGFloat { ((screen ?? NSScreen.main)?.frame.width ?? 1728) / 1728 }
}
final class WeatherViewModel: ObservableObject {
    static let shared = WeatherViewModel()
    var iconName = "location.slash", temperature = "--", locationName = "天气不可用"
    var conditionDescription = "", windInfo = "--", precipChance = "--", humidity = "--"
}
enum NotchWidgetMode { case weatherPlayer }
private struct NavigationStackKey: EnvironmentKey {
    static let defaultValue: Binding<[NotchWidgetMode]> = .constant([])
}
extension EnvironmentValues {
    var navigationStack: Binding<[NotchWidgetMode]> {
        get { self[NavigationStackKey.self] }
        set { self[NavigationStackKey.self] = newValue }
    }
}

@main struct WidgetLayoutProbe {
    @MainActor static func main() {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let ordered: [WidgetType] = [.music, .weather, .calendar, .focusSession, .battery]
        let budget: CGFloat = 1512 * 0.72 - 140 * (1512 / 1728)
        // Actual card contracts, independently of the estimator under test.
        let widths: [WidgetType: CGFloat] = [.music: 300, .weather: 260, .calendar: 240, .focusSession: 200, .battery: 210]
        for dividers in [false, true] {
            let selected = WidgetLayoutPolicy.fittingWidgets(from: ordered, availableWidth: budget, showDividers: dividers)
            let renderedWidth = selected.reduce(CGFloat(0)) { $0 + widths[$1]! }
                + CGFloat(max(0, selected.count - 1)) * (dividers ? 41 : 20)
            check(renderedWidth <= budget, "selected cards overflow: \(renderedWidth) > \(budget), dividers=\(dividers)")
            check(selected.first == .music, "music must retain saved order priority")
            print("selected=\(selected.map(\.rawValue)) renderedWidth=\(renderedWidth) budget=\(budget)")
        }
        // Boundary budgets distinguish the actual Focus minimum from the old 190 estimate.
        check(WidgetLayoutPolicy.fittingWidgets(from: [.music, .focusSession], availableWidth: 515, showDividers: false) == [.music], "Focus must not fit below its actual 520pt row width")
        check(WidgetLayoutPolicy.fittingWidgets(from: [.music, .focusSession], availableWidth: 520, showDividers: false) == [.music, .focusSession], "Focus must fit at the exact 520pt boundary")
        // The Divider is a separate HStack child with a spacing interval on both sides.
        let dividerRow = NSHostingView(rootView: HStack(spacing: 20) {
            Color.clear.frame(width: 300, height: 90)
            Divider().frame(height: 60)
            Color.clear.frame(width: 240, height: 90)
        })
        let dividerRowWidth = dividerRow.fittingSize.width
        print("hostedDividerRowWidth=\(dividerRowWidth)")
        check(abs(dividerRowWidth - 581) < 0.5, "actual divider HStack must occupy 581pt")
        check(abs(WidgetLayoutPolicy.totalWidth(for: [.music, .calendar], showDividers: true) - dividerRowWidth) < 0.5, "divider estimator must match hosted row")
        check(WidgetLayoutPolicy.fittingWidgets(from: [.music, .calendar], availableWidth: 580, showDividers: true) == [.music], "divider row must not fit below 581pt")
        check(WidgetLayoutPolicy.fittingWidgets(from: [.music, .calendar], availableWidth: 581, showDividers: true) == [.music, .calendar], "divider row must fit at exact 581pt boundary")
        check(WidgetLayoutPolicy.fittingWidgets(from: ordered, availableWidth: budget, showDividers: false, bypassSpaceLimit: true) == ordered, "explicit bypass must retain all widgets")
        for message in [
            "Grant Location access in Sapphire's Permissions settings to show weather.",
            "请在 Sapphire 的权限设置中允许定位，以显示天气。",
            "Location access was denied. Please enable it in System Settings.",
            "晴"
        ] {
            WeatherViewModel.shared.conditionDescription = message
            let host = NSHostingView(rootView: WeatherWidgetView())
            let size = host.fittingSize
            print("weather messageLength=\(message.count) fittingWidth=\(size.width)")
            check(size.width <= 260.5, "weather text expands card: \(size.width) > 260")
            check(size.height >= 90, "weather card lost minimum height")
        }
        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, wind, temperature) in [("beijing-8", "8公里/时", "21°"), ("beijing-128", "128公里/时", "21°"), ("beijing-negative", "128公里/时", "-21°")] {
                let model = WeatherViewModel.shared
                model.iconName = "cloud.fill"
                model.temperature = temperature
                model.locationName = "北京市"
                model.conditionDescription = "阴"
                model.windInfo = wind
                model.precipChance = "0%"
                model.humidity = "59%"
                let host = NSHostingView(rootView: WeatherWidgetView().background(Color.black))
                host.frame = CGRect(x: 0, y: 0, width: 260, height: 100)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: image)
                try! image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
                print("rendered \(name) wind=\(wind) width=\(host.fittingSize.width)")
            }
        }
        if failures.isEmpty { print("PASS: real widget selection and hosted weather width") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
