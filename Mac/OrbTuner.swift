import AppKit
import MetalKit
import SwiftUI

/// The orb settings the Orb Tuner edits, saved between launches.
@Observable
final class OrbTuningStore {
    var tuning: OrbTuning {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(tuning), forKey: Self.key) }
    }

    private static let key = "orbTuning"

    init() {
        tuning = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(OrbTuning.self, from: $0) } ?? .standard
    }
}

/// One slider in the tuner, in plain words.
struct OrbKnob: Identifiable {
    let id: String
    let title: String
    let help: String
    let range: ClosedRange<Float>
    let path: WritableKeyPath<OrbTuning, Float>
    var unit = ""

    static let sections: [(String, String, [OrbKnob])] = [
        ("Hearing you", "How the orb picks up your voice.", [
            OrbKnob(id: "sensitivity", title: "Mic sensitivity",
                    help: "Turn up if the orb barely moves when you talk softly. Turn down if it overreacts.",
                    range: 0.25...4, path: \.sensitivity, unit: "×"),
            OrbKnob(id: "threshold", title: "Wake-up loudness",
                    help: "How loud you need to be before the orb counts it as talking. Lower wakes it up for whispers.",
                    range: 0.05...0.8, path: \.threshold),
            OrbKnob(id: "attack", title: "Reaction speed",
                    help: "How fast it jumps when you make a sound. Higher feels snappy, lower feels smooth.",
                    range: 0.05...1, path: \.attack),
            OrbKnob(id: "release", title: "Settle speed",
                    help: "How fast it calms down after a sound. Lower lets each bump melt away slowly.",
                    range: 0.01...0.5, path: \.release),
        ]),
        ("Shape while you talk", "How much the blob bulges, and which parts of your voice do it.", [
            OrbKnob(id: "reaction", title: "Overall bounce",
                    help: "One knob for how much your voice reshapes the blob.",
                    range: 0...3, path: \.reaction, unit: "×"),
            OrbKnob(id: "low", title: "Deep sounds → big swells",
                    help: "Low, deep parts of your voice push out the biggest, slowest bulges.",
                    range: 0...0.4, path: \.low),
            OrbKnob(id: "mid", title: "Middle sounds → medium bumps",
                    help: "The main body of your voice (vowels) moves the medium bumps.",
                    range: 0...0.3, path: \.mid),
            OrbKnob(id: "high", title: "Crisp sounds → small ripples",
                    help: "Sharp sounds like “s”, “t” and “k” make the smaller ripples.",
                    range: 0...0.25, path: \.high),
            OrbKnob(id: "puff", title: "Loudness puff",
                    help: "Makes the whole blob swell a little when you speak louder.",
                    range: 0...0.2, path: \.puff),
        ]),
        ("Movement", "How it moves on its own.", [
            OrbKnob(id: "idle", title: "Resting wobble",
                    help: "How much it moves while you're quiet. 0 makes it a still ball between words.",
                    range: 0...3, path: \.idle, unit: "×"),
            OrbKnob(id: "lumps", title: "Lump size",
                    help: "Lower means a few big, soft lumps. Higher means many smaller lumps.",
                    range: 0.4...2.5, path: \.lumps, unit: "×"),
            OrbKnob(id: "flow", title: "Flow speed",
                    help: "How fast the surface churns, like a lava lamp speeding up or slowing down.",
                    range: 0...3, path: \.flow, unit: "×"),
            OrbKnob(id: "talkBoost", title: "Extra speed while talking",
                    help: "How much faster it churns while you're talking.",
                    range: 0...2, path: \.talkBoost),
            OrbKnob(id: "spin", title: "Spin",
                    help: "How fast it slowly turns. 0 stops the turning.",
                    range: 0...1, path: \.spin),
        ]),
        ("Look", "Color and finish.", [
            OrbKnob(id: "hue", title: "Color",
                    help: "0 is Taki purple. Slide left for pinks and reds, right for blues and teals.",
                    range: -180...180, path: \.hue, unit: "°"),
            OrbKnob(id: "brightness", title: "Brightness",
                    help: "Darker or lighter overall.",
                    range: 0.4...2.5, path: \.brightness, unit: "×"),
            OrbKnob(id: "shine", title: "Shine",
                    help: "The wet, glossy highlights. 0 makes it matte.",
                    range: 0...3, path: \.shine, unit: "×"),
            OrbKnob(id: "glow", title: "Edge glow",
                    help: "The soft violet glow around its edge that keeps it visible on dark windows.",
                    range: 0...3, path: \.glow, unit: "×"),
            OrbKnob(id: "voiceLight", title: "Lights up when you talk",
                    help: "How much the bumps brighten while you speak.",
                    range: 0...3, path: \.voiceLight, unit: "×"),
        ]),
        ("On your screen", "Where the floating orb sits while you dictate.", [
            OrbKnob(id: "size", title: "Size", help: "How big the floating orb is.",
                    range: 100...420, path: \.size, unit: " pt"),
            OrbKnob(id: "bottom", title: "Height from the bottom",
                    help: "How far above the bottom of the screen (or the Dock) it floats.",
                    range: 0...600, path: \.bottom, unit: " pt"),
        ]),
    ]

    func format(_ value: Float) -> String {
        let digits = range.upperBound - range.lowerBound >= 50 ? 0 : 2
        return String(format: "%.\(digits)f", value) + unit
    }
}

struct OrbTunerWindow: View {
    @Bindable var model: MacModel
    @State private var copied = false

    private var store: OrbTuningStore { model.orbTuning }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 14) {
                OrbPreview(voice: model.voice, tuning: store)
                    .frame(width: 280, height: 280)
                    .background(Color(red: 0.06, green: 0.03, blue: 0.1), in: .rect(cornerRadius: 20))
                Toggle("Try it with my voice", isOn: Binding(
                    get: { model.orbPreviewing }, set: { model.setOrbPreview($0) }))
                    .toggleStyle(.switch)
                Text(model.orbPreviewing
                     ? "Talk and watch it move. The orb at the bottom of your screen shows the real size and spot. Nothing is recorded or typed."
                     : "Turn this on and talk to see your changes live.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Copy My Settings") { copySettings() }
                    .buttonStyle(.borderedProminent)
                Text(copied ? "Copied. Paste it to Devin to make this the default."
                            : "When you like it, copy your settings and send them to Devin.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset Everything") { store.tuning = .standard; model.orbLayoutChanged() }
                    .disabled(store.tuning == .standard)
            }
            .padding(20)
            .frame(width: 320)

            Form {
                ForEach(OrbKnob.sections, id: \.0) { title, subtitle, knobs in
                    Section {
                        ForEach(knobs) { knob in KnobRow(knob: knob, store: store) { model.orbLayoutChanged() } }
                    } header: {
                        Text(title)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 820, minHeight: 600)
        .onDisappear { model.setOrbPreview(false) }
    }

    private func copySettings() {
        let lines = OrbKnob.sections.flatMap(\.2).map { "\($0.title): \($0.format(store.tuning[keyPath: $0.path]))" }
        let json = (try? JSONEncoder().encode(store.tuning)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        model.copy("My Taki orb settings:\n" + lines.joined(separator: "\n") + "\n\n" + json)
        copied = true
    }
}

private struct KnobRow: View {
    let knob: OrbKnob
    @Bindable var store: OrbTuningStore
    let changed: () -> Void

    private var value: Float { store.tuning[keyPath: knob.path] }
    private var standard: Float { OrbTuning.standard[keyPath: knob.path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(knob.title).fontWeight(.medium)
                Spacer()
                Text(knob.format(value)).monospacedDigit().foregroundStyle(.secondary)
                Button {
                    store.tuning[keyPath: knob.path] = standard
                    changed()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Back to default (\(knob.format(standard)))")
                .opacity(value == standard ? 0 : 1)
                .disabled(value == standard)
            }
            Slider(value: Binding(get: { value }, set: { store.tuning[keyPath: knob.path] = $0; changed() }),
                   in: knob.range)
            Text(knob.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

/// The live orb inside the tuner window.
private struct OrbPreview: NSViewRepresentable {
    let voice: VoiceLevels
    let tuning: OrbTuningStore

    func makeCoordinator() -> OrbRenderer? {
        let renderer = OrbRenderer(model: voice)
        renderer?.dark = true
        renderer?.tuningSource = { [weak tuning] in tuning?.tuning ?? .standard }
        return renderer
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: OrbRenderer.device)
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 60
        context.coordinator?.attach(to: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
