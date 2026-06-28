import Foundation

enum GFXCodec: String, Codable, CaseIterable, Identifiable {
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

enum NetworkType: String, Codable, CaseIterable, Identifiable {
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
struct RDPSettings: Codable, Equatable {
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
    var autoReconnect: Bool = true
    /// Before connecting to Linux hosts, detect a pinned GNOME remote-monitor layout
    /// (e.g. Meta-0 at 200% scale) and reset it over SSH so the session stays usable.
    var autoRecoverDisplay: Bool = true

    static let `default` = RDPSettings()
}
