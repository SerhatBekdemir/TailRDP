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
        case .avc420:      return "AVC420 — smoother over Tailscale"
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

/// How the RDP client window is shown — maps to stored `fullscreen` / `dynamicResolution` flags.
enum RDPDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case window
    case resizable
    case fullscreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .window: return "Fixed window"
        case .resizable: return "Resizable window"
        case .fullscreen: return "Fullscreen"
        }
    }

    func helpText(macOS: Bool) -> String {
        switch self {
        case .window:
            return "Opens at the resolution below. Good when you want a specific size or 16:9 ratio."
        case .resizable:
            return "Drag the window edges to resize — the remote desktop follows."
        case .fullscreen:
            if macOS {
                return "Opens at your chosen resolution. Click the green fullscreen button on the RDP window when ready. Exit with Ctrl+⌘+F."
            }
            return "Starts in fullscreen."
        }
    }
}

/// Per-host RDP launch settings.
struct RDPSettings: Codable, Equatable, Sendable {
    var dynamicResolution: Bool = false
    var width: Int = 1920
    var height: Int = 1080
    var fullscreen: Bool = false
    var multiMonitor: Bool = false
    var codec: GFXCodec = .avc420
    var bpp: Int = 32
    var network: NetworkType = .lan
    var clipboard: Bool = true
    var sound: Bool = true
    var mapCmdToCtrl: Bool = true
    var autoReconnect: Bool = false
    var smartReconnect: Bool = true

    static let `default` = RDPSettings()
    static let recommendedFullscreenWidth = 1920
    static let recommendedFullscreenHeight = 1080

    enum CodingKeys: String, CodingKey {
        case dynamicResolution, width, height, fullscreen, multiMonitor
        case codec, bpp, network, clipboard, sound, mapCmdToCtrl, autoReconnect
        case smartReconnect
        case autoDiagnoseOnFailure
        case autoRecoverDisplay
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dynamicResolution = try c.decodeIfPresent(Bool.self, forKey: .dynamicResolution) ?? false
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? false
        multiMonitor = try c.decodeIfPresent(Bool.self, forKey: .multiMonitor) ?? false
        codec = try c.decodeIfPresent(GFXCodec.self, forKey: .codec) ?? .avc420
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
        normalizeDisplayOptions()
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

    var displayMode: RDPDisplayMode {
        get {
            if fullscreen { return .fullscreen }
            if dynamicResolution { return .resizable }
            return .window
        }
        set { apply(displayMode: newValue) }
    }

    mutating func apply(displayMode mode: RDPDisplayMode) {
        switch mode {
        case .window:
            fullscreen = false
            dynamicResolution = false
        case .resizable:
            fullscreen = false
            dynamicResolution = true
        case .fullscreen:
            fullscreen = true
            dynamicResolution = false
            multiMonitor = false
            if !isRecommendedFullscreenResolution {
                width = Self.recommendedFullscreenWidth
                height = Self.recommendedFullscreenHeight
            }
        }
    }

    mutating func normalizeDisplayOptions() {
        if fullscreen {
            dynamicResolution = false
            multiMonitor = false
        } else if dynamicResolution {
            fullscreen = false
        }
    }

    var isRecommendedFullscreenResolution: Bool {
        width == Self.recommendedFullscreenWidth && height == Self.recommendedFullscreenHeight
    }
}

extension RDPSettings {
    static var safeFallback: RDPSettings {
        var s = RDPSettings()
        s.width = 1920
        s.height = 1080
        s.bpp = 16
        s.codec = .avc420
        s.network = .lan
        s.dynamicResolution = false
        return s
    }

    var connectSummary: String {
        let display: String
        switch displayMode {
        case .window:
            display = "\(width)×\(height)"
        case .resizable:
            display = "resizable"
        case .fullscreen:
            display = "fullscreen \(width)×\(height)"
        }
        return "\(display), \(codec.rawValue), \(network.rawValue)"
    }
}
