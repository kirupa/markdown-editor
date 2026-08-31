import Foundation
import MarkdownEditorCore

/// Runs the konvo critique pass over a document and hands back a report.
///
/// The work is done by the GitHub Copilot CLI in non-interactive mode. That is
/// a deliberate choice over talking to a model directly: the CLI already holds
/// the user's sign-in, already knows where their skills live, and already
/// picks a model — so the app needs no API key of its own, stores no
/// credential, and gains no second thing to keep working.
///
/// What it costs is a dependency the app cannot install. Every way that can
/// fail is therefore a named case below, because "nothing happened" is the one
/// outcome a person cannot act on.
@MainActor
final class CritiqueService {
    enum Failure: LocalizedError, Equatable {
        case cliNotFound
        case documentIsEmpty
        case cancelled
        case cliFailed(status: Int32, message: String)
        case unreadableReply(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "The GitHub Copilot CLI was not found."
            case .documentIsEmpty:
                return "There is nothing to critique yet."
            case .cancelled:
                return "The critique was stopped."
            case .cliFailed:
                return "The critique could not be completed."
            case .unreadableReply:
                return "The critique came back in a form the editor could not read."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .cliNotFound:
                return """
                    A critique is written by the konvo skill running in the \
                    GitHub Copilot CLI, which the editor runs on your behalf. \
                    Install it with `npm install -g @github/copilot`, sign in \
                    once with `copilot`, and try again.
                    """
            case .documentIsEmpty:
                return "Write a paragraph or two, then ask for a critique."
            case .cancelled:
                return nil
            case .cliFailed(_, let message):
                return message.isEmpty
                    ? "The Copilot CLI stopped without explaining why."
                    : message
            case .unreadableReply(let detail):
                return """
                    The model replied, but not with a report this editor could \
                    read. \(detail)
                    """
            }
        }
    }

    private var running: Process?

    var isRunning: Bool { running?.isRunning == true }

    /// Where the Copilot CLI is, or nil when it is nowhere this can find it.
    ///
    /// `PATH` first, because a person who installed it deliberately should win.
    /// Then the versioned cache the CLI's own updater writes, which is where it
    /// lives on a machine that has only ever run it through an IDE — and is
    /// exactly the case where the app would otherwise say "not installed" to
    /// somebody looking at it running in another window.
    static func locateCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let searchPaths = (environment["PATH"] ?? "").split(separator: ":")
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("copilot")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let cache = home.appendingPathComponent(
            CritiqueRequest.sdkCacheRelativePath
        )
        let versions = (try? fileManager.contentsOfDirectory(atPath: cache.path))
            ?? []
        guard let newest = CritiqueRequest.newestVersion(among: versions) else {
            return nil
        }
        let candidate = cache
            .appendingPathComponent(newest)
            .appendingPathComponent("copilot")
        return fileManager.isExecutableFile(atPath: candidate.path)
            ? candidate
            : nil
    }

    /// Runs a critique and returns the report, or throws something explainable.
    func critique(document: String) async throws -> CritiqueReport {
        let trimmed = document.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.documentIsEmpty }
        guard let cli = Self.locateCLI() else { throw Failure.cliNotFound }

        let reply = try await run(cli: cli, prompt: CritiqueRequest.prompt(
            forDocument: document
        ))
        do {
            return try CritiqueReportDecoder.decode(reply)
        } catch {
            // The reply is kept out of the message on purpose: it can be long,
            // and the first line is usually the CLI explaining itself, which
            // is the useful part.
            let firstLine = reply
                .split(separator: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? ""
            throw Failure.unreadableReply(firstLine)
        }
    }

    func cancel() {
        running?.terminate()
        running = nil
    }

    private func run(cli: URL, prompt: String) async throws -> String {
        let process = Process()
        process.executableURL = cli
        process.arguments = [
            "--prompt", prompt,
            // Non-interactive mode refuses to start without this. Nothing here
            // asks the model to touch the disk — the draft is in the prompt —
            // and the tools it could reach for are switched off below.
            "--allow-all-tools",
            "--deny-tool", "shell",
            "--deny-tool", "write",
            "--deny-tool", "edit",
            "--no-ask-user",
            // A critique is about the words in front of it. The repository's
            // own instructions would be read as guidance about the draft.
            "--no-custom-instructions",
            "--disable-builtin-mcps",
            "--no-color",
            "--log-level", "none",
        ]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // A document window is not a terminal. Without this the CLI inherits
        // whatever stdin the app happened to have and can sit waiting on it.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.cliFailed(status: -1, message: error.localizedDescription)
        }
        running = process

        let (stdout, stderr) = await Task.detached {
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (out, err)
        }.value

        running = nil
        let reply = String(decoding: stdout, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal {
                throw Failure.cancelled
            }
            let message = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.cliFailed(
                status: process.terminationStatus,
                message: message.isEmpty ? reply : message
            )
        }
        return reply
    }
}
