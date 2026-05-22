//
//  JkdsSpaceSDK.swift
//  독립 구현: JkdsSpacePrivateSDK 없이 NearbyInteraction + CoreBluetooth 직접 사용
//

import CoreBluetooth
import NearbyInteraction

public class JkdsSpaceSDK {
    private let uwbManager = SpaceUWBManager()

    public init() {}

    public func startUWBRanging(
        maximumConnectionCount: Int = 4,
        replacementDistanceThreshold: Float = 8,
        isConnectStrongestSignalFirst: Bool = true,
        uwbUpdateTimeoutSeconds: Int = 5,
        onUpdate: @escaping (UWBRangeResult) -> Void,
        onDisconnect: @escaping (UWBDisconnectResult) -> Void
    ) {
        uwbManager.onRangeUpdate = onUpdate
        uwbManager.onDisconnect = onDisconnect

        uwbManager.startRanging(
            maximumConnectionCount: maximumConnectionCount,
            replacementDistanceThreshold: replacementDistanceThreshold,
            isConnectStrongestSignalFirst: isConnectStrongestSignalFirst,
            uwbUpdateTimeoutSeconds: uwbUpdateTimeoutSeconds
        )
    }

    public func stopUWBRanging(onComplete: @escaping (Result<Void, Error>) -> Void) {
        uwbManager.stopAll()
        onComplete(.success(()))
    }

    public func disconnectDevice(named deviceName: String) -> Bool {
        return uwbManager.disconnectDevice(named: deviceName)
    }

    public func setDeviceBlocked(_ deviceName: String, blocked: Bool) {
        uwbManager.setDeviceBlocked(deviceName, blocked: blocked)
    }
}
