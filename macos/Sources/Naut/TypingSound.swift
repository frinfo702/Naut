import AppKit
import AVFoundation
import NautKit

/// Plays the chosen switch's recordings as keys go down and up in the
/// editors. Each file is decoded once; a few players take turns so fast
/// typing overlaps instead of cutting the last sound off.
@MainActor
final class TypingSound {
    static let shared = TypingSound()

    var sound: KeySound = .off {
        didSet { if sound != oldValue { buffers = [:] } }
    }

    var volume: Float = 1

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    /// Every recording is 44.1 kHz mono.
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private let root = Bundle.main.resourceURL?.appendingPathComponent("KeySounds")

    func keyDown(_ event: NSEvent) {
        guard !event.isARepeat, event.modifierFlags.isDisjoint(with: [.command, .control]) else { return }
        play(sound.file(keyCode: event.keyCode, down: true))
    }

    func keyUp(_ event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return }
        play(sound.file(keyCode: event.keyCode, down: false))
    }

    /// A letter going down, for the settings and palette previews.
    func preview(_ sound: KeySound? = nil) {
        play((sound ?? self.sound).file(keyCode: 0, down: true))
    }

    private func play(_ file: String?) {
        guard let file, let buffer = buffer(file), start() else { return }
        let player = players[next]
        next = (next + 1) % players.count
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    private func buffer(_ file: String) -> AVAudioPCMBuffer? {
        if let b = buffers[file] { return b }
        guard let url = root?.appendingPathComponent(file + ".mp3"),
              let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil
        else { return nil }
        buffers[file] = b
        return b
    }

    private func start() -> Bool {
        if players.isEmpty {
            for _ in 0 ..< 6 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
                players.append(p)
            }
        }
        if engine.isRunning { return true }
        return (try? engine.start()) != nil
    }
}
