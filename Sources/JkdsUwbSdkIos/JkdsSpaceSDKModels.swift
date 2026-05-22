//
//  JkdsSpaceSDKModels.swift
//  UWBRangeResult, UWBDisconnectResult, DisconnectTypeResult 모델 정의
//  Bundled from SpaceSDK-iOS-master/Sources/JkdsSpaceSDK/Model/
//

import Foundation

// MARK: - UWB Range Result

public struct UWBRangeResult: Codable {
    public let deviceName: String
    public let distance: Float
    public let direction: [Float]
    public let azimuth: Int
    public let elevation: Int
}

// MARK: - Disconnect Type

public enum DisconnectTypeResult {
    case disconnectedDueToDistance
    case disconnectedDueToSystem
    case disconnectedDueToTimeout
}

public struct UWBDisconnectResult {
    public let disConnectType: DisconnectTypeResult
    public let deviceName: String
}

// MARK: - RTLS

public struct RTLSAnchorResult {
    public let id: String
    public let x: Double
    public let y: Double
    public let z: Double
    public let distance: Double

    public init(id: String, x: Double, y: Double, z: Double, distance: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.z = z
        self.distance = distance
    }
}

public struct TagLocationResult {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
