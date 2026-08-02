import AppKit
import BranchLensCore
import MarkdownUI
import SwiftUI

struct ImagePreviewPane: View {
    let title: String
    let subtitle: String
    let accent: Color
    let data: Data?
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let data {
                    Text(byteLabel(for: data.count))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppTheme.subtleFill, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppTheme.subtleFill)

            Divider().opacity(0.45)

            Group {
                if let data, let nsImage = NSImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: max(nsImage.size.width, 1),
                                maxHeight: max(nsImage.size.height, 1)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(16)
                    }
                    .background(AppTheme.canvas)
                } else {
                    Text(placeholder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(AppTheme.canvas)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func byteLabel(for count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }
}

struct MarkdownPreviewPane: View {
    let title: String
    let subtitle: String
    let accent: Color
    let source: String?
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.subtleFill, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppTheme.subtleFill)

            Divider().opacity(0.45)

            Group {
                if let source, !source.isEmpty {
                    ScrollView {
                        Markdown(source)
                            .markdownTheme(.gitHub)
                            .markdownTextStyle(\.text) {
                                FontSize(15)
                                ForegroundColor(.primary)
                            }
                            .markdownTextStyle(\.code) {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.88))
                                BackgroundColor(Color.primary.opacity(0.08))
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                    .background(AppTheme.canvas)
                } else {
                    Text(placeholder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(AppTheme.canvas)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct CodePane: View {
    let title: String
    let subtitle: String
    let accent: Color
    let source: String?
    let path: String
    let placeholder: String
    var lineCount: Int = 0
    var searchQuery: String = ""
    /// 1-based source line numbers to tint (Compare mode).
    var emphasizedLines: Set<Int> = []
    var lineEmphasis: SyntaxLineEmphasis = .none
    var markdownPreview: Bool = false

    var body: some View {
        if markdownPreview {
            MarkdownPreviewPane(
                title: title,
                subtitle: subtitle,
                accent: accent,
                source: source,
                placeholder: placeholder
            )
        } else {
            sourcePane
        }
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if source != nil {
                    Text("\(lineCount) lines")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppTheme.subtleFill, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppTheme.subtleFill)

            Divider().opacity(0.45)

            Group {
                if let source {
                    SyntaxTextView(
                        source: source,
                        path: path,
                        showLineNumbers: true,
                        searchQuery: searchQuery,
                        emphasizedLines: emphasizedLines,
                        lineEmphasis: lineEmphasis
                    )
                } else {
                    Text(placeholder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(AppTheme.canvas)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
