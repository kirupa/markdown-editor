import Foundation
import FirebaseStorage
import MarkdownEditorCloud

/// Cloud Storage, behind the three calls `CloudAssetStore` asks for.
///
/// Image bytes live here rather than in Firestore because a Firestore document
/// is capped at 1 MiB and base64 inflates a file by about a third, which would
/// cap an inserted image near 700 KB *and* spend the same budget the document's
/// text needs. The Firestore node keeps only a pointer. See `README.md`.
public struct FirebaseAssetStore: CloudAssetStore {
    /// Only the account ID is stored, for the reason given in
    /// `FirestoreNodeStore`: `StorageReference` is not `Sendable`.
    private let uid: String

    public init(uid: String) {
        self.uid = uid
    }

    /// Object paths are namespaced by account so the Storage rules can be a
    /// path match, exactly as the Firestore rules are.
    private func reference(for storagePath: String) -> StorageReference {
        Storage.storage().reference()
            .child("\(FirebaseConfiguration.usersCollection)/\(uid)/\(storagePath)")
    }

    public func upload(_ data: Data, to storagePath: String, contentType: String?) async throws -> String {
        let metadata = StorageMetadata()
        if let contentType { metadata.contentType = contentType }

        do {
            let reference = reference(for: storagePath)
            _ = try await reference.putDataAsync(data, metadata: metadata)
            return try await reference.downloadURL().absoluteString
        } catch {
            throw Self.translate(error, doing: "upload \(CloudPath.name(of: storagePath))")
        }
    }

    /// Storage has no server-side copy, so the bytes come down and go back up.
    ///
    /// Only reached when a document is renamed or moved, which is rare and
    /// which the alternative — leaving the images behind — would break.
    public func copy(from: String, to: String) async throws -> String {
        do {
            let data = try await reference(for: from).data(maxSize: Int64(CloudWorkspace.maximumImageBytes))
            let metadata = try? await reference(for: from).getMetadata()
            return try await upload(data, to: to, contentType: metadata?.contentType)
        } catch let error as CloudError {
            throw error
        } catch {
            throw Self.translate(error, doing: "move \(CloudPath.name(of: from))")
        }
    }

    /// Failures are collected rather than thrown on the first one.
    ///
    /// This runs after the nodes pointing at these objects are already gone, so
    /// stopping half way would leave more orphans than continuing. An object
    /// that is already missing is not a failure — the outcome asked for has
    /// happened.
    public func removeAll(_ storagePaths: [String]) async throws {
        for path in storagePaths {
            do {
                try await reference(for: path).delete()
            } catch {
                let code = StorageErrorCode(rawValue: (error as NSError).code)
                if code == .objectNotFound { continue }
                print("Could not delete \(path): \(error.localizedDescription)")
            }
        }
    }

    static func translate(_ error: Error, doing: String) -> CloudError {
        switch StorageErrorCode(rawValue: (error as NSError).code) {
        case .unauthenticated:
            return .notSignedIn
        case .unauthorized:
            return .permissionDenied(doing)
        case .quotaExceeded:
            return .underlying("This project's Cloud Storage quota is used up, so it could not \(doing).")
        case .bucketNotFound, .projectNotFound:
            // The most likely failure on a new project: the bucket has never
            // been created. Worth naming, because "an unknown error occurred"
            // sends people looking in the wrong place.
            return .storageUnavailable(doing)
        case .retryLimitExceeded:
            return .offline(doing)
        default:
            return .underlying("Could not \(doing). \(error.localizedDescription)")
        }
    }
}
