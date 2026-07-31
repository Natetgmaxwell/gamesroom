//
//  CasinoConfig.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Per-room casino configuration. (`VisionProvider` lives in its own
/// file — `VisionProvider.swift` — to keep this file focused on the
/// `CasinoConfig` shape.) Drives the chip tray and the
/// vision pipeline. Two chips-to-points regimes are supported:
///
/// - `standardPresets == true` ⇒ use `ChipColor.defaultValue`
///   regardless of `chipColorMap` (the room's table is canonical).
/// - `standardPresets == false` ⇒ use `chipColorMap` per color,
///   falling back to `ChipColor.defaultValue` for unmapped colors.
struct CasinoConfig: Codable, Identifiable, Hashable {
    let roomId: UUID

    /// Whether the casino pack is enabled in this room. Disabled
    /// rooms still decode the row but the Witness Screen suppresses
    /// the chip tray.
    var enabled: Bool

    /// Manual chip color → points overrides. Empty when
    /// `standardPresets == true`.
    var chipColorMap: [ChipColor: Int]

    /// Whether to use `ChipColor.defaultValue` (no per-room
    /// overrides).
    var standardPresets: Bool

    /// Vision provider choice. Defaults to `.onDevice` so existing
    /// rooms decoded from older RPC responses still parse.
    var visionProvider: VisionProvider

    /// Optional model id for the hosted vision provider.
    var visionModel: String?

    /// API key for the hosted vision provider. `nil` ⇒ falls back to
    /// the on-device path.
    var visionApiKey: String?

    /// Stable identity — the roomId is the primary key.
    var id: UUID { roomId }

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case enabled
        case chipColorMap = "chip_color_map"
        case standardPresets = "standard_presets"
        case visionProvider = "vision_provider"
        case visionModel = "vision_model"
        case visionApiKey = "vision_api_key"
    }

    init(
        roomId: UUID,
        enabled: Bool,
        chipColorMap: [ChipColor: Int],
        standardPresets: Bool,
        visionProvider: VisionProvider = .onDevice,
        visionModel: String? = nil,
        visionApiKey: String? = nil
    ) {
        self.roomId = roomId
        self.enabled = enabled
        self.chipColorMap = chipColorMap
        self.standardPresets = standardPresets
        self.visionProvider = visionProvider
        self.visionModel = visionModel
        self.visionApiKey = visionApiKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        standardPresets = try c.decode(Bool.self, forKey: .standardPresets)

        // The backend persists the map as `{ "red": 5, ... }`. It
        // sometimes arrives wrapped in a JSON-as-string fallback;
        // we accept both shapes to keep older rows alive.
        let raw: [String: Int]
        if let dict = try? c.decodeIfPresent([String: Int].self, forKey: .chipColorMap) {
            raw = dict
        } else if let json = try? c.decodeIfPresent(String.self, forKey: .chipColorMap),
                  let data = json.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            raw = dict
        } else {
            raw = [:]
        }
        chipColorMap = Dictionary(uniqueKeysWithValues: raw.compactMap { key, val in
            ChipColor(rawValue: key).map { color in
                (color, color == .custom ? 0 : val)
            }
        })

        let providerRaw = try c.decodeIfPresent(String.self, forKey: .visionProvider)
            ?? VisionProvider.onDevice.rawValue
        visionProvider = VisionProvider(rawValue: providerRaw) ?? .onDevice
        visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel)
        visionApiKey = try c.decodeIfPresent(String.self, forKey: .visionApiKey)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(roomId, forKey: .roomId)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(standardPresets, forKey: .standardPresets)
        try c.encode(
            Dictionary(uniqueKeysWithValues: chipColorMap.map { ($0.key.rawValue, $0.value) }),
            forKey: .chipColorMap
        )
        try c.encode(visionProvider.rawValue, forKey: .visionProvider)
        try c.encodeIfPresent(visionModel, forKey: .visionModel)
        try c.encodeIfPresent(visionApiKey, forKey: .visionApiKey)
    }

    /// Resolve the point value for a color. Honors `standardPresets`
    /// first, then the per-room override map, then the color's
    /// built-in default. `custom` always returns 0 (no default).
    func value(for color: ChipColor) -> Int {
        if standardPresets { return color.defaultValue }
        if let mapped = chipColorMap[color] { return mapped }
        return color.defaultValue
    }
}
