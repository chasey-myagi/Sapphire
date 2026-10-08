//
//  BluetoothManager.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2025-07-07.
//

import Foundation
import Combine
import IOBluetooth
import CoreBluetooth
import AppKit

struct BluetoothDeviceState: Hashable {
    enum EventType: Hashable {
        case connected, disconnected, batteryLow
    }
    let eventUUID = UUID()
    let id: String, name: String, iconName: String, eventType: EventType
    var batteryLevel: Int? = nil
    let isContinuityDevice: Bool
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.eventUUID == rhs.eventUUID }
    func hash(into hasher: inout Hasher) { hasher.combine(eventUUID) }
}

@MainActor
class BluetoothManager: NSObject, ObservableObject {
    @Published var lastEvent: BluetoothDeviceState?

    var isBluetoothPoweredOn: Bool {
        guard isMonitoring, authorization() == .allowedAlways else { return false }
        return readPowerState()
    }

    private var connectionNotification: IOBluetoothUserNotification?
    private var disconnectionNotifications: [String: IOBluetoothUserNotification] = [:]
    private var recentlyConnectedDebounceSet: Set<String> = []

    private var batteryReader: BluetoothBatteryReader { .shared }
    private let readPowerState: () -> Bool
    private let authorization: () -> CBManagerAuthorization
    private let beginObservation: ((BluetoothManager) -> (() -> Void)?)?
    private var endObservation: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var isProximityScanActive = false
    private var monitoringGeneration = 0
    private var initialBatteryRefresh: Task<Void, Never>?

    init(
        authorization: @escaping () -> CBManagerAuthorization = { CBManager.authorization },
        beginObservation: ((BluetoothManager) -> (() -> Void)?)? = nil,
        readPowerState: @escaping () -> Bool = { IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON }
    ) {
        self.readPowerState = readPowerState
        self.authorization = authorization
        self.beginObservation = beginObservation
        super.init()
    }

    private(set) var isMonitoring = false

    func startMonitoring() {
        guard authorization() == .allowedAlways else {
            stopMonitoring()
            return
        }
        guard !isMonitoring else { return }
        monitoringGeneration += 1
        isMonitoring = true
        if let beginObservation {
            endObservation = beginObservation(self)
        } else {
            endObservation = installObservation()
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        monitoringGeneration += 1
        isProximityScanActive = false
        endObservation?()
        endObservation = nil
        connectionNotification?.unregister()
        connectionNotification = nil
        disconnectionNotifications.values.forEach { $0.unregister() }
        disconnectionNotifications.removeAll()
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
        recentlyConnectedDebounceSet.removeAll()
        lastEvent = nil
    }

    private func installObservation() -> (() -> Void)? {
        ud.register(defaults: ["readBTDevice": true, "readBTHID": true, "readIDevice": true, "updateInterval": 1])

        let generation = monitoringGeneration
        SPBluetoothDataModel.shared.refeshData { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentObservation(generation) else { return }
                self.checkForInitiallyConnectedDevices()
            }
        }

        if initialBatteryRefresh == nil {
            initialBatteryRefresh = Task { [weak self] in
                guard let self else { return }
                defer { self.initialBatteryRefresh = nil }
                guard self.isMonitoring, self.authorization() == .allowedAlways else { return }
                // The shared reader owns its batch; retain it until completion to avoid overlapping restarts.
                await self.batteryReader.refreshAllBatteries()
            }
        }

        self.connectionNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAirPodsUpdate(_:)),
            name: .didUpdateAirPodsBattery,
            object: nil
        )

        AuthenticationManager.shared.$isScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isScanning in
                guard let self, self.isCurrentObservation(generation) else { return }
                self.isProximityScanActive = isScanning
            }
            .store(in: &cancellables)
        return nil
    }

    private func isCurrentObservation(_ generation: Int) -> Bool {
        isMonitoring && monitoringGeneration == generation && authorization() == .allowedAlways
    }

    func makeEventDelivery() -> @MainActor (BluetoothDeviceState?) -> Void {
        let generation = monitoringGeneration
        return { [weak self] event in
            guard let self, self.isCurrentObservation(generation) else { return }
            self.lastEvent = event
        }
    }

    deinit {
        endObservation?()

        connectionNotification?.unregister()
        disconnectionNotifications.values.forEach { $0.unregister() }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAirPodsUpdate(_ notification: Notification) {
        let generation = monitoringGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentObservation(generation) else { return }
            self.handleAirPodsUpdateOnMain(notification)
        }
    }

    @MainActor
    private func handleAirPodsUpdateOnMain(_ notification: Notification) {
        let deliver = makeEventDelivery()
        guard isCurrentObservation(monitoringGeneration), !isProximityScanActive else { return }

        guard let userInfo = notification.userInfo,
              let bleName = userInfo["name"] as? String,
              let level = userInfo["level"] as? Int else {
            return
        }

        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let classicDevice = pairedDevices.first(where: {
                  guard let classicName = $0.name else { return false }
                  let cleanClassic = classicName.replacingOccurrences(of: "(ANC)", with: "").replacingOccurrences(of: " ", with: "").lowercased()
                  let cleanBLE = bleName.replacingOccurrences(of: "- Find My", with: "").replacingOccurrences(of: "’s", with: "").replacingOccurrences(of: " ", with: "").lowercased()
                  return cleanBLE.contains(cleanClassic) || cleanClassic.contains(cleanBLE)
              }) else {
            return
        }

        let iconName = IconMapper.icon(for: classicDevice)
        let deviceState = BluetoothDeviceState(
            id: classicDevice.addressString,
            name: classicDevice.name ?? bleName,
            iconName: iconName,
            eventType: .connected,
            batteryLevel: level,
            isContinuityDevice: isContinuityDevice(name: classicDevice.name ?? bleName)
        )
        deliver(deviceState)
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard notification === connectionNotification else { return }
        let generation = monitoringGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentObservation(generation) else { return }
            self.handleDeviceConnected(device: device)
        }
    }

    @MainActor
    private func handleDeviceConnected(device: IOBluetoothDevice) {
        let deliver = makeEventDelivery()
        let generation = monitoringGeneration
        guard isCurrentObservation(generation) else { return }
        guard !isProximityScanActive else {
            registerForDisconnect(device: device)
            return
        }

        guard let address = device.addressString, let name = device.name else { return }

        if recentlyConnectedDebounceSet.contains(address) { return }
        recentlyConnectedDebounceSet.insert(address)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.isCurrentObservation(generation) else { return }
            self.recentlyConnectedDebounceSet.remove(address)
        }

        if SettingsModel.shared.settings.bluetoothNotifySound {
            if let soundURL = Bundle.main.url(forResource: "head_gestures_double_nod", withExtension: "caf") {
                NSSound(contentsOf: soundURL, byReference: true)?.play()
            } else {
                NSSound(named: "Tink")?.play()
            }
        }

        let lowercasedName = name.lowercased()
        if lowercasedName.contains("airpods") || lowercasedName.contains("beats") {
            registerForDisconnect(device: device)
            return
        }

        let batteryStatus = IconMapper.getBatteryStatus(for: device)
        let iconName = IconMapper.icon(for: device)

        switch batteryStatus {
        case .noBattery:
            let deviceState = BluetoothDeviceState(
                id: address, name: name, iconName: iconName,
                eventType: .connected, batteryLevel: nil,
                isContinuityDevice: isContinuityDevice(name: name)
            )
            deliver(deviceState)

        case .hasBattery:
            Task {
                let batteryLevel = await findBatteryLevel(for: device, generation: generation)
                guard isCurrentObservation(generation) else { return }
                let deviceState = BluetoothDeviceState(
                    id: address, name: name, iconName: iconName,
                    eventType: .connected, batteryLevel: batteryLevel,
                    isContinuityDevice: isContinuityDevice(name: name)
                )
                deliver(deviceState)
            }

        case .unknown:
            let immediateState = BluetoothDeviceState(
                id: address, name: name, iconName: iconName,
                eventType: .connected, batteryLevel: nil,
                isContinuityDevice: isContinuityDevice(name: name)
            )
            deliver(immediateState)

            Task {
                let batteryLevel = await findBatteryLevel(for: device, generation: generation)
                guard isCurrentObservation(generation) else { return }

                IconMapper.learnDeviceBatteryStatus(address: address, hasBattery: batteryLevel != nil)

                if let level = batteryLevel {
                    let updatedState = BluetoothDeviceState(
                        id: address, name: name, iconName: iconName,
                        eventType: .connected, batteryLevel: level,
                        isContinuityDevice: isContinuityDevice(name: name)
                    )
                    deliver(updatedState)
                }
            }
        }

        registerForDisconnect(device: device)
    }

    private func findBatteryLevel(for device: IOBluetoothDevice, generation: Int) async -> Int? {
        guard isCurrentObservation(generation), let name = device.name else { return nil }

        if device.isMultiBatteryDevice {
            let l = device.batteryPercentLeft
            let r = device.batteryPercentRight
            let valid = [l, r].filter { $0 > 0 && $0 <= 100 }
            if !valid.isEmpty { return valid.reduce(0, +) / valid.count }
        } else {
            if let single = device.batteryPercentSingle as? Int, single > 0 && single <= 100 {
                return single
            }
        }

        MagicBattery.shared.getIOBTBattery()
        if let cachedDevice = AirBatteryModel.getByName(name),
           cachedDevice.batteryLevel > 0 && cachedDevice.batteryLevel <= 100 {
            return cachedDevice.batteryLevel
        }

        await withCheckedContinuation { continuation in
            SPBluetoothDataModel.shared.refeshData { _ in
                continuation.resume()
            } error: {
                continuation.resume()
            }
        }

        guard isCurrentObservation(generation) else { return nil }
        MagicBattery.shared.getIOBTBattery()
        if let batteryDevice = AirBatteryModel.getByName(name), batteryDevice.batteryLevel > 0 && batteryDevice.batteryLevel <= 100 {
            print("[BluetoothManager] Found battery level for [\(name)]: \(batteryDevice.batteryLevel)%")
            return batteryDevice.batteryLevel
        }

        let sysProfileBatteries = await BluetoothBatteryReader.getSystemProfileBatteries()
        guard isCurrentObservation(generation) else { return nil }
        if let match = sysProfileBatteries.first(where: { $0.name == name }), match.level > 0, match.level <= 100 {
            print("[BluetoothManager] System profile battery for [\(name)]: \(match.level)%")
            return match.level
        }

        await batteryReader.refreshAllBatteries()
        if let cached = AirBatteryModel.getByName(name), cached.batteryLevel > 0, cached.batteryLevel <= 100 {
            return cached.batteryLevel
        }

        return nil
    }

    private func registerForDisconnect(device: IOBluetoothDevice) {
        guard isCurrentObservation(monitoringGeneration), let address = device.addressString else { return }
        if self.disconnectionNotifications[address] == nil {
            self.disconnectionNotifications[address] = device.register(
                forDisconnectNotification: self,
                selector: #selector(self.deviceDisconnected(_:device:))
            )
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard isCurrentObservation(monitoringGeneration), let address = device.addressString,
              disconnectionNotifications[address] === notification else { return }
        let generation = monitoringGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentObservation(generation) else { return }
            self.handleDeviceDisconnected(device: device)
        }
    }

    @MainActor
    private func handleDeviceDisconnected(device: IOBluetoothDevice) {
        let deliver = makeEventDelivery()
        guard isCurrentObservation(monitoringGeneration) else { return }
        guard !isProximityScanActive else {
            if let address = device.addressString, let notificationToRemove = disconnectionNotifications.removeValue(forKey: address) {
                notificationToRemove.unregister()
            }
            return
        }

        guard let address = device.addressString, let name = device.name else { return }

        if SettingsModel.shared.settings.bluetoothNotifySound {
            if let soundURL = Bundle.main.url(forResource: "jbl_cancel", withExtension: "caf") {
                NSSound(contentsOf: soundURL, byReference: true)?.play()
            } else {
                NSSound(named: "Tink")?.play()
            }
        }

        let iconName = IconMapper.icon(for: device)

        let deviceState = BluetoothDeviceState(
            id: address, name: name, iconName: iconName,
            eventType: .disconnected, isContinuityDevice: isContinuityDevice(name: name)
        )
        deliver(deviceState)

        if let notificationToRemove = disconnectionNotifications.removeValue(forKey: address) {
            notificationToRemove.unregister()
        }
    }

    private func checkForInitiallyConnectedDevices() {
        guard isCurrentObservation(monitoringGeneration),
              let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        for device in pairedDevices where device.isConnected() {
            handleDeviceConnected(device: device)
        }
    }

    private func isContinuityDevice(name: String) -> Bool {
        let lowercasedName = name.lowercased()
        let keywords = ["macbook", "imac", "mac mini", "mac studio", "mac pro", "iphone", "ipad", "apple watch", "vision pro"]
        return keywords.contains { lowercasedName.contains($0) }
    }
}