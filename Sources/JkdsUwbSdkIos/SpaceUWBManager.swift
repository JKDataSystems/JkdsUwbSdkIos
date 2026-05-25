//
//  SpaceUWBManager.swift
//  react-native-jkdsspace-sdk
//
//  독립 구현: NearbyInteraction + CoreBluetooth를 사용한 UWB 거리 측정 매니저
//  JkdsSpacePrivateSDK 의존성 없이 동작합니다.
//

import Foundation
import CoreBluetooth
import NearbyInteraction

// MARK: - BLE Service UUIDs (Nordic UART Service — Android와 동일)
fileprivate struct UUIDS {
    let kNUSServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9F")
    let kNUSRxCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9F") // Phone → Device
    let kNUSTxCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9F") // Device → Phone
}



// MARK: - OoB Message IDs (Android OoBHelper과 동일)

private struct OoBMessageId {
    static let uwbDeviceConfigurationData: UInt8 = 1
    static let uwbDidStart: UInt8 = 2
    static let uwbDidStop: UInt8 = 3
    static let initialize: UInt8 = 0xA5 // -91 as unsigned
    static let uwbPhoneConfigurationData: UInt8 = 11 // Ascii VT
    static let stop: UInt8 = 12 // Ascii FF
}

// MARK: - Connected Accessory

private class ConnectedAccessory {
    let peripheral: CBPeripheral
    var name: String
    var niSession: NISession?
    var rxCharacteristic: CBCharacteristic?
    var txCharacteristic: CBCharacteristic?
    var isUwbActive: Bool = false
    
    init(peripheral: CBPeripheral, name: String) {
        self.peripheral = peripheral
        self.name = name
    }
}

// MARK: - SpaceUWBManager

/// BLE 스캔 + NearbyInteraction UWB 세션을 직접 관리하는 독립 구현 클래스
final class SpaceUWBManager: NSObject {
    
    // MARK: Callbacks
    var onRangeUpdate: ((UWBRangeResult) -> Void)?
    var onDisconnect: ((UWBDisconnectResult) -> Void)?
    
    // MARK: Configuration
    private var maximumConnectionCount: Int = 4
    private var replacementDistanceThreshold: Float = 8.0
    private var uwbUpdateTimeoutSeconds: Int = 5
    
    // MARK: Internal State
    private var centralManager: CBCentralManager?    
    private var accessories: [UUID: ConnectedAccessory] = [:]
    private var isScanning: Bool = false
    private var blockedDeviceNames: Set<String> = []
    private var timeoutTimers: [UUID: Timer] = [:]
    
    // MARK: - Public API
    
    func startRanging(
        maximumConnectionCount: Int,
        replacementDistanceThreshold: Float,
        isConnectStrongestSignalFirst: Bool,
        uwbUpdateTimeoutSeconds: Int
    ) {
        self.maximumConnectionCount = maximumConnectionCount
        self.replacementDistanceThreshold = replacementDistanceThreshold
        self.uwbUpdateTimeoutSeconds = uwbUpdateTimeoutSeconds
        
        stopAll()
        
        centralManager = CBCentralManager(delegate: self, queue: .main)
        startScanning()
    }
    
    func stopAll() {
        // Cancel all timeout timers
        for (_, timer) in timeoutTimers {
            timer.invalidate()
        }
        timeoutTimers.removeAll()
        
        // Close all NI sessions
        for (_, accessory) in accessories {
            accessory.niSession?.invalidate()
            if let peripheral = centralManager?.retrievePeripherals(withIdentifiers: [accessory.peripheral.identifier]).first {
                centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
        accessories.removeAll()
        
        // Stop scanning
        if isScanning {
            centralManager?.stopScan()
            isScanning = false
        }
    }

    func disconnectDevice(named deviceName: String) -> Bool {
        guard let entry = accessories.first(where: { $0.value.name == deviceName }) else {
            return false
        }
        let accessory = entry.value
        accessory.niSession?.invalidate()
        centralManager?.cancelPeripheralConnection(accessory.peripheral)
        timeoutTimers[entry.key]?.invalidate()
        timeoutTimers.removeValue(forKey: entry.key)
        accessories.removeValue(forKey: entry.key)
        
        onDisconnect?(UWBDisconnectResult(
            disConnectType: .disconnectedDueToSystem,
            deviceName: deviceName
        ))
        return true
    }

    func setDeviceBlocked(_ deviceName: String, blocked: Bool) {
        if blocked {
            blockedDeviceNames.insert(deviceName)
            _ = disconnectDevice(named: deviceName)
        } else {
            blockedDeviceNames.remove(deviceName)
        }
    }
    
    // MARK: - BLE Scanning
    private func startScanning() {
        guard let cm = centralManager, cm.state == .poweredOn else { return }
        cm.scanForPeripherals(
            withServices: [UUIDS().kNUSServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
    }
    
    // MARK: - OoB Message Handling
    private func sendInitialize(to accessory: ConnectedAccessory) {
        guard let rx = accessory.rxCharacteristic else { return }
        let data = Data([OoBMessageId.initialize])
        accessory.peripheral.writeValue(data, for: rx, type: .withoutResponse)
    }
    
    private func handleReceivedData(_ data: Data, from accessory: ConnectedAccessory) {
        guard !data.isEmpty else { return }
        let messageId = data[0]
        
        switch messageId {
        case OoBMessageId.uwbDeviceConfigurationData:
            // Device sent its UWB config → start NearbyInteraction session
            let payload = data.dropFirst()
            startNISession(for: accessory, deviceConfig: Data(payload))
            
        case OoBMessageId.uwbDidStart:
            accessory.isUwbActive = true
            
        case OoBMessageId.uwbDidStop:
            accessory.isUwbActive = false
            
        default:
            break
        }
    }
    
    // MARK: - NearbyInteraction Session
    private func startNISession(for accessory: ConnectedAccessory, deviceConfig: Data) {
        guard NISession.isSupported else {
            NSLog("[SpaceUWBManager] NearbyInteraction is not supported on this device")
            return
        }
        
        let session = NISession()
        let delegate = NISessionDelegateHandler(manager: self, accessory: accessory)
        session.delegate = delegate
        accessory.niSession = session
        
        // Parse device config and create NI configuration
        // The device sends its discovery token; we create a peer configuration from it
        if let peerToken = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NIDiscoveryToken.self, from: deviceConfig
        ) {
            let config = NINearbyPeerConfiguration(peerToken: peerToken)
            session.run(config)
            startTimeoutTimer(for: accessory)
        } else {
            // Fallback: try to use the raw bytes as a discovery token
            // Some devices may use a different encoding
            NSLog("[SpaceUWBManager] Failed to decode NI discovery token from device config")
        }
    }
    
    
    private func startTimeoutTimer(for accessory: ConnectedAccessory) {
        let id = accessory.peripheral.identifier
        timeoutTimers[id]?.invalidate()
        timeoutTimers[id] = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(uwbUpdateTimeoutSeconds),
            repeats: false
        ) { [weak self, id] _ in
            guard let accessory = self?.accessories[id] else { return }
            self?.handlePeerDisconnect(accessory: accessory, type: .disconnectedDueToTimeout)
        }
    }
    
    private func resetTimeoutTimer(for accessory: ConnectedAccessory) {
        startTimeoutTimer(for: accessory)
    }
    
    // MARK: - Disconnect Handling
    fileprivate func handlePeerDisconnect(accessory: ConnectedAccessory, type: DisconnectTypeResult) {
        let id = accessory.peripheral.identifier
        accessory.niSession?.invalidate()
        centralManager?.cancelPeripheralConnection(accessory.peripheral)
        timeoutTimers[id]?.invalidate()
        timeoutTimers.removeValue(forKey: id)
        accessories.removeValue(forKey: id)
        
        onDisconnect?(UWBDisconnectResult(
            disConnectType: type,
            deviceName: accessory.name
        ))
    }
    
    // MARK: - Range Result Handling
    fileprivate func handleRangeResult(accessory: ConnectedAccessory, result: NINearbyObject) {
        resetTimeoutTimer(for: accessory)
        let distance = result.distance ?? 0
        let direction = result.direction ?? simd_float3(0, 0, 0)
        let azimuth = atan2(direction.x, direction.z) * 180.0 / .pi
        let elevation = asin(direction.y) * 180.0 / .pi
        
        let rangeResult = UWBRangeResult(
            deviceName: accessory.name,
            distance: distance,
            direction: [direction.x, direction.y, direction.z],
            azimuth: Int(azimuth),
            elevation: Int(elevation)
        )
        onRangeUpdate?(rangeResult)
    }
}

// MARK: - CBCentralManagerDelegate

extension SpaceUWBManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            stopAll()
        default:
            break
        }
    }
    
    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.identifier.uuidString
        
        // Skip blocked devices
        if blockedDeviceNames.contains(name) { return }
        
        // Skip if already connected/connecting
        if accessories[peripheral.identifier] != nil { return }
        
        // Check connection limit
        if accessories.count >= maximumConnectionCount { return }
        
        // Connect
        let accessory = ConnectedAccessory(peripheral: peripheral, name: name)
        accessories[peripheral.identifier] = accessory
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([UUIDS().kNUSServiceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        accessories.removeValue(forKey: peripheral.identifier)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let accessory = accessories[peripheral.identifier] else { return }
        handlePeerDisconnect(accessory: accessory, type: .disconnectedDueToSystem)
    }
}

// MARK: - CBPeripheralDelegate

extension SpaceUWBManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == UUIDS().kNUSServiceUUID {
            peripheral.discoverCharacteristics([UUIDS().kNUSRxCharUUID, UUIDS().kNUSTxCharUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        guard let accessory = accessories[peripheral.identifier] else { return }
        
        for char in chars {
            if char.uuid == UUIDS().kNUSRxCharUUID {
                accessory.rxCharacteristic = char
            } else if char.uuid == UUIDS().kNUSTxCharUUID {
                accessory.txCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
        
        // Both characteristics found → send initialize
        if accessory.rxCharacteristic != nil && accessory.txCharacteristic != nil {
            sendInitialize(to: accessory)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              let data = characteristic.value,
              let accessory = accessories[peripheral.identifier] else { return }
        handleReceivedData(data, from: accessory)
    }
}

// MARK: - NISessionDelegate Handler

private class NISessionDelegateHandler: NSObject, NISessionDelegate {
    weak var manager: SpaceUWBManager?
    let accessory: ConnectedAccessory
    
    init(manager: SpaceUWBManager, accessory: ConnectedAccessory) {
        self.manager = manager
        self.accessory = accessory
    }
    
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let nearbyObject = nearbyObjects.first else { return }
        manager?.handleRangeResult(accessory: accessory, result:nearbyObject)
    }
    
    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        switch reason {
        case .peerEnded:
            manager?.handlePeerDisconnect(accessory: accessory, type: .disconnectedDueToSystem)
        case .timeout:
            manager?.handlePeerDisconnect(accessory: accessory, type: .disconnectedDueToTimeout)
        @unknown default:
            manager?.handlePeerDisconnect(accessory: accessory, type: .disconnectedDueToSystem)
        }
    }
    
    func sessionWasSuspended(_ session: NISession) {
        // Session will resume when app returns to foreground
    }
    
    func sessionSuspensionEnded(_ session: NISession) {
        // Session resumed — re-run with existing config if available
    }
    
    func session(_ session: NISession, didInvalidateWith error: Error) {
        self.manager?.handlePeerDisconnect(accessory: accessory, type: .disconnectedDueToSystem)
    }
}

