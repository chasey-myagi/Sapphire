import XCTest
import CoreBluetooth
@testable import Sapphire

final class BluetoothLifecycleTests: XCTestCase {
    @MainActor
    func testConstructionDoesNotAcquireBluetoothHardware() {
        var acquisitions = 0
        let manager = BluetoothManager(authorization: { .notDetermined }, beginObservation: { _ in
            acquisitions += 1
            return {}
        })
        XCTAssertEqual(acquisitions, 0, "Opening the app must not acquire Bluetooth hardware")
        XCTAssertNil(manager.lastEvent)
    }
    @MainActor
    func testUnauthorizedStartAndPowerQueryDoNotAccessHardware() {
        for authorization in [CBManagerAuthorization.notDetermined, .denied, .restricted] {
            var acquisitions = 0
            var powerReads = 0
            let manager = BluetoothManager(authorization: { authorization }, beginObservation: { _ in
                acquisitions += 1
                return {}
            }, readPowerState: {
                powerReads += 1
                return true
            })
            manager.startMonitoring()
            manager.startMonitoring()
            XCTAssertFalse(manager.isBluetoothPoweredOn)
            manager.stopMonitoring()
            XCTAssertEqual(acquisitions, 0, "Unauthorized startup must not register or query devices")
            XCTAssertEqual(powerReads, 0, "Unauthorized UI must not query the Bluetooth host controller")
            XCTAssertFalse(manager.isMonitoring)
        }
    }
    @MainActor
    func testGrantRevokeAndRestartOwnOneObservationAtATime() {
        var authorization = CBManagerAuthorization.allowedAlways
        var activeObservations = 0
        var cleanups = 0
        let manager = BluetoothManager(authorization: { authorization }, beginObservation: { _ in
            activeObservations += 1
            return {
                activeObservations -= 1
                cleanups += 1
            }
        }, readPowerState: { true })
        manager.startMonitoring()
        manager.startMonitoring()
        XCTAssertTrue(manager.isMonitoring)
        XCTAssertTrue(manager.isBluetoothPoweredOn)
        XCTAssertEqual(activeObservations, 1)

        authorization = .denied
        manager.startMonitoring()
        XCTAssertFalse(manager.isMonitoring)
        XCTAssertFalse(manager.isBluetoothPoweredOn)
        XCTAssertEqual(activeObservations, 0)
        XCTAssertEqual(cleanups, 1)

        authorization = .allowedAlways
        manager.startMonitoring()
        XCTAssertEqual(activeObservations, 1)
        manager.stopMonitoring()
        manager.stopMonitoring()
        XCTAssertFalse(manager.isMonitoring)
        XCTAssertEqual(activeObservations, 0)
        XCTAssertEqual(cleanups, 2)
        XCTAssertNil(manager.lastEvent)
    }

    @MainActor
    func testBLEWithoutScanOrMonitorIntentNeverAllocatesCentralManager() {
        let ble = BLE()
        XCTAssertNil(ble.initializedCentralManager)
        for passive in [true, false, true] {
            ble.setPassiveMode(passive)
            ble.stopScanning()
            ble.stopMonitor()
            XCTAssertNil(ble.initializedCentralManager)
            XCTAssertFalse(ble.isScanningContinuously)
            XCTAssertNil(ble.proximityTimer)
            XCTAssertNil(ble.signalTimer)
            XCTAssertNil(ble.activeModeTimer)
            XCTAssertNil(ble.connectionTimer)
        }
    }
    @MainActor
    func testStoppingMonitorCancelsItsPendingConnectionTimeoutWithoutAllocatingHardware() {
        let ble = BLE()
        let timeout = Timer(timeInterval: 60, repeats: false) { _ in }
        ble.connectionTimer = timeout
        ble.stopMonitor()
        XCTAssertNil(ble.connectionTimer)
        XCTAssertFalse(timeout.isValid)
        XCTAssertNil(ble.initializedCentralManager)
    }

    @MainActor
    func testPowerReadsRequireRunningAndAuthorizedAndStopClearsPublishedEvent() {
        var authorization = CBManagerAuthorization.allowedAlways
        var powerReads = 0
        let manager = BluetoothManager(authorization: { authorization }, beginObservation: { _ in {} }, readPowerState: {
            powerReads += 1
            return true
        })
        XCTAssertFalse(manager.isBluetoothPoweredOn)
        XCTAssertEqual(powerReads, 0)
        manager.startMonitoring()
        XCTAssertTrue(manager.isBluetoothPoweredOn)
        XCTAssertEqual(powerReads, 1)
        manager.lastEvent = event("connected")
        XCTAssertNotNil(manager.lastEvent)
        manager.stopMonitoring()
        XCTAssertNil(manager.lastEvent)
        XCTAssertFalse(manager.isBluetoothPoweredOn)
        XCTAssertEqual(powerReads, 1)

        manager.startMonitoring()
        XCTAssertTrue(manager.isBluetoothPoweredOn)
        XCTAssertEqual(powerReads, 2)
        authorization = .denied
        XCTAssertTrue(manager.isMonitoring, "Revoke is tested before another start/stop reconciles state")
        XCTAssertFalse(manager.isBluetoothPoweredOn)
        XCTAssertEqual(powerReads, 2)
        manager.stopMonitoring()
    }

    @MainActor
    func testUnauthorizedBLEExplicitScanAndSavedMonitorDoNotAcquireHardwareOrIntent() {
        for authorization in [CBManagerAuthorization.notDetermined, .denied, .restricted] {
            let ble = BLE(authorization: { authorization })
            for includeUnnamed in [false, true] {
                ble.startScanning(includeUnnamed: includeUnnamed)
                ble.startMonitor(uuid: UUID())
                XCTAssertNil(ble.initializedCentralManager)
                XCTAssertFalse(ble.isScanningContinuously)
                XCTAssertNil(ble.monitoredUUID)
                XCTAssertNil(ble.monitoredPeripheral)
                XCTAssertNil(ble.proximityTimer)
                XCTAssertNil(ble.signalTimer)
                XCTAssertNil(ble.activeModeTimer)
                XCTAssertNil(ble.connectionTimer)
                ble.stopScanning()
                ble.stopMonitor()
            }
        }
    }

    @MainActor
    func testEventCompletionsCannotCrossStopRestartOrClearNewObservation() {
        var authorization = CBManagerAuthorization.allowedAlways
        let manager = BluetoothManager(authorization: { authorization }, beginObservation: { _ in {} })
        manager.startMonitoring()
        let deliverA = manager.makeEventDelivery()
        let a = event("A")
        deliverA(a)
        XCTAssertEqual(manager.lastEvent, a)
        manager.stopMonitoring()
        XCTAssertNil(manager.lastEvent)
        deliverA(a)
        XCTAssertNil(manager.lastEvent)

        manager.startMonitoring()
        let deliverB = manager.makeEventDelivery()
        let b = event("B")
        deliverA(a)
        XCTAssertNil(manager.lastEvent)
        deliverB(b)
        XCTAssertEqual(manager.lastEvent, b)
        deliverA(nil)
        XCTAssertEqual(manager.lastEvent, b, "Old completion cannot clear the new observation")
        deliverA(a)
        XCTAssertEqual(manager.lastEvent, b, "Old completion cannot replace the new observation")
        deliverB(nil)
        XCTAssertNil(manager.lastEvent)
        deliverB(b)
        XCTAssertEqual(manager.lastEvent, b)

        authorization = .denied
        deliverB(a)
        XCTAssertEqual(manager.lastEvent, b)
        deliverB(nil)
        XCTAssertEqual(manager.lastEvent, b, "Revoked completion cannot publish or clear")
        manager.stopMonitoring()
        deliverB(b)
        XCTAssertNil(manager.lastEvent)
    }

    private func event(_ id: String) -> BluetoothDeviceState {
        BluetoothDeviceState(id: id, name: id, iconName: "headphones", eventType: .connected, isContinuityDevice: false)
    }
}
