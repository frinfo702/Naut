import Foundation

/// A keyboard's sound: recordings of real switches, from kbsim
/// (github.com/tplai/kbsim, MIT), shipped in Naut.app/Contents/Resources/KeySounds.
/// Each switch has a press per keyboard row plus space, return and
/// backspace, and a release.
public enum KeySound: String, CaseIterable, Identifiable, Sendable {
    case off
    case mxblue
    case mxbrown
    case mxblack
    case cream
    case holypanda
    case topre
    case buckling

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .mxblue: "Cherry MX Blue"
        case .mxbrown: "Cherry MX Brown"
        case .mxblack: "Cherry MX Black"
        case .cream: "NovelKeys Cream"
        case .holypanda: "Holy Panda"
        case .topre: "Topre"
        case .buckling: "Buckling Spring"
        }
    }

    /// The recording's path under KeySounds for a key going down or up.
    /// MX Blue has no special keys; they fall back to the generic ones.
    public func file(keyCode: UInt16, down: Bool) -> String? {
        guard self != .off else { return nil }
        let special: String? = switch keyCode {
        case 49: "SPACE"
        case 36, 76: "ENTER"
        case 51, 117: "BACKSPACE"
        default: nil
        }
        let name: String
        if let special, self != .mxblue {
            name = special
        } else if down {
            name = "GENERIC_R\(Self.row(keyCode))"
        } else {
            name = "GENERIC"
        }
        return "\(rawValue)/\(down ? "press" : "release")/\(name)"
    }

    /// The keyboard row, top to bottom, on an ANSI layout; anything off
    /// the four main rows sounds like the bottom one.
    static func row(_ keyCode: UInt16) -> Int {
        switch keyCode {
        case 50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24: 0
        case 48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42: 1
        case 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39: 2
        case 6, 7, 8, 9, 11, 45, 46, 43, 47, 44: 3
        default: 4
        }
    }
}
