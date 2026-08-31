import SwiftUI

struct OpenPullRequestField: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a GitHub pull request URL", text: $workspace.openPullRequestDraft)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task { await workspace.openPullRequest(from: workspace.openPullRequestDraft) }
                    }
                    .disabled(workspace.isOpeningPullRequest)
                if workspace.isOpeningPullRequest {
                    ProgressView()
                        .controlSize(.small)
                } else if !workspace.openPullRequestDraft.isEmpty {
                    Button {
                        Task { await workspace.openPullRequest(from: workspace.openPullRequestDraft) }
                    } label: {
                        Text("Open")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let status = workspace.openPullRequestStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = workspace.openPullRequestError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OpenPullRequestSheet: View {
    @ObservedObject var workspace: WorkspaceModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Pull Request")
                .font(.title2.weight(.semibold))
            Text("BranchLens looks up the PR, finds a local clone and worktree, then inspects the head branch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            OpenPullRequestField(workspace: workspace)
                .focused($fieldFocused)

            HStack {
                Spacer()
                Button("Cancel") {
                    workspace.isOpenPullRequestPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(workspace.isOpeningPullRequest)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            DispatchQueue.main.async {
                fieldFocused = true
            }
        }
    }
}
