@testable import BranchLensCore
import Foundation
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testDesktopPathIncludesHomebrewWithoutReplacingInheritedEnvironment() {
        let environment = ProcessRunner.subprocessEnvironment([
            "PATH": "/custom/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_SSH_COMMAND": "custom-ssh",
        ])
        let paths = environment["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(Array(paths.prefix(5)), ["/custom/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        XCTAssertTrue(paths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(paths.contains("/usr/local/bin"))
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertEqual(environment["GIT_SSH_COMMAND"], "custom-ssh")
    }

    func testMissingPathGetsStandardExecutableLocations() {
        let environment = ProcessRunner.subprocessEnvironment([:])
        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testGitCanStageLFSPointerWithDesktopLaunchEnvironment() async throws {
        guard ["/opt/homebrew/bin/git-lfs", "/usr/local/bin/git-lfs"].contains(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("Requires Git LFS installed in a Homebrew location")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-lens-lfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"

        func git(_ arguments: [String]) async throws -> String {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                currentDirectory: root,
                environment: environment
            )
            guard result.status == 0 else {
                throw GitError.commandFailed(result.stderrText)
            }
            return result.stdoutText
        }

        _ = try await git(["init"])
        _ = try await git(["config", "filter.lfs.process", "git-lfs filter-process"])
        _ = try await git(["config", "filter.lfs.required", "true"])
        try "*.mp4 filter=lfs -text\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let contents = "test video contents\n"
        try contents.write(to: root.appendingPathComponent("clip.mp4"), atomically: true, encoding: .utf8)

        _ = try await git(["add", "--", ".gitattributes", "clip.mp4"])
        let staged = try await git(["show", ":clip.mp4"])
        XCTAssertTrue(staged.hasPrefix("version https://git-lfs.github.com/spec/v1\n"), staged)
        XCTAssertTrue(staged.contains("oid sha256:"), staged)
        XCTAssertTrue(staged.contains("size \(contents.utf8.count)"), staged)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("clip.mp4"), encoding: .utf8), contents)
    }
}
