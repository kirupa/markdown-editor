import Foundation
import MarkdownEditorContract

// Writes the contract fixtures. Run it after changing anything in
// MarkdownEditorCore or CloudPath:
//
//     swift run --package-path Shared markdown-contract Contract
//
// A test asserts the committed files match what this produces, so forgetting
// to run it fails the suite rather than going unnoticed.

let arguments = CommandLine.arguments
let directory = URL(
    fileURLWithPath: arguments.count > 1 ? arguments[1] : "Contract",
    isDirectory: true
)

do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, data) in try ContractFixtures.files().sorted(by: { $0.key < $1.key }) {
        let target = directory.appendingPathComponent(name)
        try data.write(to: target, options: .atomic)
        let size = Double(data.count) / 1024
        print(String(format: "%@  %.0f KB", target.path, size))
    }
} catch {
    FileHandle.standardError.write(Data("Could not write the fixtures: \(error)\n".utf8))
    exit(1)
}
