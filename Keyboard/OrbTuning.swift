import Foundation

/// Every knob that shapes how the orb looks and moves with the voice. `standard` is the shipped look;
/// the Mac app's Orb Tuner edits a copy live.
struct OrbTuning: Codable, Equatable {
    // Listening
    var sensitivity: Float = 1
    var threshold: Float = 0.3
    var attack: Float = 0.55
    var release: Float = 0.12
    // Shape
    var reaction: Float = 1
    var low: Float = 0.13
    var mid: Float = 0.09
    var high: Float = 0.06
    var puff: Float = 0.04
    var idle: Float = 1
    var lumps: Float = 1
    // Motion
    var flow: Float = 1
    var talkBoost: Float = 0.6
    var spin: Float = 0.12
    // Look
    var hue: Float = 0
    var brightness: Float = 1
    var shine: Float = 1
    var glow: Float = 1
    var voiceLight: Float = 1
    // On screen (Mac overlay)
    var size: Float = 220
    var bottom: Float = 24

    static let standard = OrbTuning()

    init() {}

    /// Missing keys keep their default, so saved settings survive new knobs.
    init(from decoder: Decoder) throws {
        let saved = try decoder.singleValueContainer().decode([String: Float].self)
        var tuning = OrbTuning()
        for (key, path) in Self.fields { if let value = saved[key] { tuning[keyPath: path] = value } }
        self = tuning
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: Self.fields.map { ($0.0, self[keyPath: $0.1]) }))
    }

    static let fields: [(String, WritableKeyPath<OrbTuning, Float>)] = [
        ("sensitivity", \.sensitivity), ("threshold", \.threshold), ("attack", \.attack), ("release", \.release),
        ("reaction", \.reaction), ("low", \.low), ("mid", \.mid), ("high", \.high), ("puff", \.puff),
        ("idle", \.idle), ("lumps", \.lumps), ("flow", \.flow), ("talkBoost", \.talkBoost), ("spin", \.spin),
        ("hue", \.hue), ("brightness", \.brightness), ("shine", \.shine), ("glow", \.glow),
        ("voiceLight", \.voiceLight), ("size", \.size), ("bottom", \.bottom),
    ]

    var shader: OrbShaderTuning {
        OrbShaderTuning(idle: idle, reaction: reaction, low: low, mid: mid, high: high, puff: puff, lumps: lumps,
                        hue: hue * .pi / 180, brightness: brightness, shine: shine, glow: glow, voiceLight: voiceLight)
    }
}

/// Must match `OrbTune` in Orb.metal.
struct OrbShaderTuning {
    var idle: Float
    var reaction: Float
    var low: Float
    var mid: Float
    var high: Float
    var puff: Float
    var lumps: Float
    var hue: Float
    var brightness: Float
    var shine: Float
    var glow: Float
    var voiceLight: Float
}
