import AppKit
import SwiftUI

struct PanelChrome<Content: View>: View {
    var fill: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                Group {
                    if let fill {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(fill)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.regularMaterial)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}

enum AppTheme {
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoNS = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let monoBoldNS = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)

    static var canvas: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var panel: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var subtleFill: Color {
        Color.primary.opacity(0.05)
    }

    /// Slightly darker panel fill for the History column.
    static var historyPanel: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.11, alpha: 1)
                : NSColor(calibratedWhite: 0.92, alpha: 1)
        })
    }

    static var additionFill: Color {
        Color(red: 0.20, green: 0.75, blue: 0.42).opacity(0.18)
    }

    static var deletionFill: Color {
        Color(red: 0.95, green: 0.35, blue: 0.38).opacity(0.18)
    }

    static var hunkFill: Color {
        Color(red: 0.35, green: 0.60, blue: 1.0).opacity(0.14)
    }

    static var additionText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.35, green: 0.88, blue: 0.55, alpha: 1)
                : NSColor(calibratedRed: 0.10, green: 0.52, blue: 0.28, alpha: 1)
        })
    }

    static var deletionText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.50, alpha: 1)
                : NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.20, alpha: 1)
        })
    }

    static var hunkText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.55, green: 0.78, blue: 1.0, alpha: 1)
                : NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.82, alpha: 1)
        })
    }

    static var plainCode: NSColor { .labelColor }
    static var keywordCode: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.45, alpha: 1)
                : NSColor(calibratedRed: 0.72, green: 0.12, blue: 0.22, alpha: 1)
        }
    }
    static var stringCode: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.65, green: 0.84, blue: 1.0, alpha: 1)
                : NSColor(calibratedRed: 0.04, green: 0.19, blue: 0.41, alpha: 1)
        }
    }
    static var commentCode: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.62, alpha: 1)
                : NSColor(calibratedRed: 0.43, green: 0.47, blue: 0.50, alpha: 1)
        }
    }
    static var numberCode: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.47, green: 0.75, blue: 1.0, alpha: 1)
                : NSColor(calibratedRed: 0.02, green: 0.31, blue: 0.68, alpha: 1)
        }
    }
}
