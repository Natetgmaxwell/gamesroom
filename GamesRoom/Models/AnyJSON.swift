//
//  AnyJSON.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  Promoted from CasinoService.swift (V0.73) alongside
//  EventTransaction so the Foundation-only test harness can
//  exercise meta decode without importing Supabase.
//

import Foundation

/// A round-trippable wrapper for arbitrary JSON values. Carries the
/// `meta` payload from `public.transactions` through the wire without
/// forcing the iOS layer to declare a per-kind schema. Same shape as
/// the V0.7.1 archived version (`RoomService.swift`).
struct AnyJSON: Codable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = v; return }
        if let v = try? c.decode(Int64.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([AnyJSON].self) { value = v.map(\.value); return }
        if let v = try? c.decode([String: AnyJSON].self) {
            value = v.mapValues(\.value); return
        }
        if c.decodeNil() { value = NSNull(); return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Int64: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case is NSNull: try c.encodeNil()
        case let v as [Any]: try c.encode(v.map(AnyJSON.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyJSON.init))
        default: try c.encodeNil()
        }
    }

    static func == (lhs: AnyJSON, rhs: AnyJSON) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}
