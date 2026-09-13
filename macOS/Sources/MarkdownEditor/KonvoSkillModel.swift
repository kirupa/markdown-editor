import Foundation
import MarkdownEditorCore
import SwiftUI

/// Reads and updates the installed konvo skill.
///
/// Everything that can be decided without a subprocess lives in `KonvoSkill`;
/// this is the part that runs `git`, which cannot be unit-tested and so is kept
/// as small as it can be.
@MainActor
final class KonvoSkillModel: ObservableObject {
    enum State: Equatable {
        case unread
        case reading
        case installed(KonvoSkill.Installed)
        case missing(KonvoSkill.Absence)
    }

    @Published private(set) var state: State = .unread
    @Published private(set) var isUpdating = false
    @Published private(set) var lastUpdate: KonvoSkill.UpdateResult?

    private var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(KonvoSkill.relativePath)
    }

    func read() {
        state = .reading
        lastUpdate = nil
        Task { [directory] in
            let result = await Self.readVersion(at: directory)
            await MainActor.run { self.state = result }
        }
    }

    func update() {
        guard !isUpdating else { return }
        isUpdating = true
        lastUpdate = nil
        Task { [directory] in
            let outcome = await Self.pull(at: directory)
            let refreshed = await Self.readVersion(at: directory)
            await MainActor.run {
                self.lastUpdate = outcome
                self.state = refreshed
                self.isUpdating = false
            }
        }
    }

    // MARK: - Running git

    private nonisolated static func readVersion(at directory: URL) async -> State {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return .missing(.notInstalled)
        }
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".git").path
        ) else {
            return .missing(.notAGitCheckout)
        }
        let log = run(
            ["log", "-1", "--format=%h%n%cI%n%s"], in: directory
        )
        guard log.status == 0,
              let installed = KonvoSkill.parse(
                log: log.output,
                status: run(["status", "--porcelain"], in: directory).output
              )
        else {
            return .missing(.unreadable(
                log.output.split(separator: "\n").first.map(String.init)
                    ?? "git could not read the skill's version."
            ))
        }
        return .installed(installed)
    }

    private nonisolated static func pull(at directory: URL) async -> KonvoSkill.UpdateResult {
        let pull = run(["pull", "--ff-only"], in: directory)
        let after = run(["log", "-1", "--format=%h"], in: directory)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return KonvoSkill.interpretPull(
            output: pull.output,
            exitCode: pull.status,
            commitAfter: after
        )
    }

    /// Runs git and returns everything it said, on both streams.
    ///
    /// `git` is located through `/usr/bin/env` rather than assumed at
    /// `/usr/bin/git`, because on a machine where the command line tools live
    /// somewhere else the absolute path is simply wrong — and the failure would
    /// read as "the skill is broken" rather than "git is elsewhere".
    private nonisolated static func run(
        _ arguments: [String],
        in directory: URL
    ) -> (output: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + arguments
        task.currentDirectoryURL = directory
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (error.localizedDescription, -1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), task.terminationStatus)
    }
}
