import Foundation

enum WeatherDisplayFormatting {
    static func measurement(_ value: Double, unit: Dimension, maximumFractionDigits: Int = 0) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: Measurement(value: value, unit: unit))
    }

    static func unavailable(unit: Unit) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitStyle = .short
        return "— \(formatter.string(from: unit))"
    }
}
