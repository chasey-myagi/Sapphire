//
//  BatteryEstimator.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2025-08-14.
//

import Foundation
import Combine
import IOKit.ps

@MainActor
class BatteryEstimator: ObservableObject {
    static let shared = BatteryEstimator(batteryMonitor: BatteryMonitor.shared)

    @Published var estimatedTimeRemaining: String?
    @Published var batteryLevel: Int = 100
    @Published var isCharging: Bool = false
    @Published private(set) var isFullyCharged: Bool = false

    private var batteryMonitor: BatteryMonitor
    private var cancellables = Set<AnyCancellable>()

    init(batteryMonitor: BatteryMonitor) {
        self.batteryMonitor = batteryMonitor

        batteryMonitor.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.update(with: state)
            }
            .store(in: &cancellables)
    }

    private func update(with state: BatteryState?) {
        isFullyCharged = false
        guard let state = state else {
            self.estimatedTimeRemaining = nil
            return
        }

        self.batteryLevel = state.level
        self.isCharging = state.isCharging

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let powerSource = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, powerSource)?.takeUnretainedValue() as? [String: AnyObject] else {
            self.estimatedTimeRemaining = nil
            return
        }

        let timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int ?? 0
        let timeToFull = info[kIOPSTimeToFullChargeKey] as? Int ?? 0
        let isCharged = info[kIOPSIsChargedKey] as? Bool ?? false
        isFullyCharged = isCharged

        if isCharged {
            self.estimatedTimeRemaining = String(localized: "Charged")
        } else if state.isCharging, timeToFull > 0 {
            self.estimatedTimeRemaining = "\(formatTime(minutes: timeToFull))"
        } else if !state.isCharging, timeToEmpty > 0 {
            self.estimatedTimeRemaining = "\(formatTime(minutes: timeToEmpty))"
        } else {
            self.estimatedTimeRemaining = ""
        }
    }

    private func formatTime(minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(minutes) * 60) ?? ""
    }
}
