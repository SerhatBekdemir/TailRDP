import Foundation

enum GFXCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case avc444 = "AVC444"
    case avc420 = "AVC420"
    case rfx = "RFX"
    case progressive = "progressive"

    var id: String { rawValue }
    var flag: String { rawValue }
    var label: String {
        switch self {
        case .avc444:      return "AVC444 — best quality"
        case .avc420:      return "AVC420 — lighter"
        case .rfx:         return "RemoteFX"
        case .progressive: return "Progressive"
        }
    }
}

enum NetworkType: String, Codable, CaseIterable, Identifiable, Sendable {
    case lan, broadband, wan, auto

    var id: String { rawValue }
    var flag: String { rawValue }
    var label: String {
        switch self {
        case .lan:       return "LAN — fastest"
        case .broadband: return "Broadband"
        case .wan:       return "WAN"
        case .auto:      return "Auto-detect"
        }
    }
}

/// Per-host RDP launch settings. Defaults mirror the known-good XPS profile.
struct RDPSettings: Codable, Equatable, Sendable {
    var dynamicResolution: Bool = false
    var width: Int = 1920
    var height: Int = 1080
    var fullscreen: Bool = false
    var multiMonitor: Bool = false
    var codec: GFXCodec = .avc444
    var bpp: Int = 32
    var network: NetworkType = .lan
    var clipboard: Bool = true
    var sound: Bool = true
    var mapCmdToCtrl: Bool = true   // ⌘ (Super) → Ctrl, so ⌘C/⌘V work over RDP
    var autoReconnect: Bool = false
    /// Fix remote host after a crash (never runs on pause or logout).
    var smartReconnect: Bool = true

    static let `default` = RDPSettings()

    enum CodingKeys: String, CodingKey {
        case dynamicResolution, width, height, fullscreen, multiMonitor
        case codec, bpp, network, clipboard, sound, mapCmdToCtrl, autoReconnect
        case smartReconnect
        case autoDiagnoseOnFailure // legacy
        case autoRecoverDisplay // legacy
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dynamicResolution = try c.decodeIfPresent(Bool.self, forKey: .dynamicResolution) ?? false
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? false
        multiMonitor = try c.decodeIfPresent(Bool.self, forKey: .multiMonitor) ?? false
        codec = try c.decodeIfPresent(GFXCodec.self, forKey: .codec) ?? .avc444
        bpp = try c.decodeIfPresent(Int.self, forKey: .bpp) ?? 32
        network = try c.decodeIfPresent(NetworkType.self, forKey: .network) ?? .lan
        clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? true
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        mapCmdToCtrl = try c.decodeIfPresent(Bool.self, forKey: .mapCmdToCtrl) ?? true
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        if let v = try c.decodeIfPresent(Bool.self, forKey: .smartReconnect) {
            smartReconnect = v
        } else if let v = try c.decodeIfPresent(Bool.self, forKey: .autoDiagnoseOnFailure) {
            smartReconnect = v
        } else {
            smartReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoRecoverDisplay) ?? true
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dynamicResolution, forKey: .dynamicResolution)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(fullscreen, forKey: .fullscreen)
        try c.encode(multiMonitor, forKey: .multiMonitor)
        try c.encode(codec, forKey: .codec)
        try c.encode(bpp, forKey: .bpp)
        try c.encode(network, forKey: .network)
        try c.encode(clipboard, forKey: .clipboard)
        try c.encode(sound, forKey: .sound)
        try c.encode(mapCmdToCtrl, forKey: .mapCmdToCtrl)
        try c.encode(autoReconnect, forKey: .autoReconnect)
        try c.encode(smartReconnect, forKey: .smartReconnect)
    }
}
