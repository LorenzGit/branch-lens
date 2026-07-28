import BranchLensCore
import SwiftUI

struct CodePane: View {
    let title: String
    let subtitle: String
    let accent: Color
    let source: String?
    let path: String
    let placeholder: String
    var lineCount: Int = 0
    var searchQuery: String = ""

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
                        searchQuery: searchQuery
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
