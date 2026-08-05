import Foundation

/// Everything the cloud workspace can refuse to do, with the recovery step
/// attached rather than left for the caller to invent.
///
/// The web build's `ApiError` carries a message and a "what to do about it"
/// line, and every cloud failure there is reported with one. This is the same
/// idea in Swift: `errorDescription` is what went wrong, and
/// `recoverySuggestion` is what to do — which is exactly the split
/// `NSAlert` and SwiftUI's `.alert` already present.
public enum CloudError: LocalizedError, Equatable {
    case invalidPath(String)
    case rootIsNotADocument
    case notFound(String)
    case notADocument(String)
    case notAFolder(String)
    case alreadyExists(String)
    case tooManyCopies(String)
    case cannotMoveIntoItself(String)
    case cannotModifyRoot
    case reservedAssetsFolder
    case imageTooLarge(bytes: Int, limit: Int)
    case unsupportedImageType(String)
    case documentTooLarge(bytes: Int, limit: Int)
    case notSignedIn
    case signInFailed(String)
    case signInCancelled
    case storageUnavailable(String)
    /// The network, or Firestore, was not reachable. Distinct from a permission
    /// failure because the answer is "wait", not "change something".
    case offline(String)
    case permissionDenied(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "“\(path)” is not a valid location."
        case .rootIsNotADocument:
            return "The workspace root is not a document."
        case .notFound(let path):
            return "“\(CloudPath.name(of: path))” could not be found."
        case .notADocument(let path):
            return "“\(CloudPath.name(of: path))” is not a document."
        case .notAFolder(let path):
            return "“\(CloudPath.name(of: path))” is not a folder."
        case .alreadyExists(let name):
            return "“\(name)” already exists here."
        case .tooManyCopies(let name):
            return "There are too many copies of “\(name)” already."
        case .cannotMoveIntoItself(let path):
            return "“\(CloudPath.name(of: path))” cannot be moved into itself."
        case .cannotModifyRoot:
            return "The workspace folder itself cannot be renamed or deleted."
        case .reservedAssetsFolder:
            return "“.assets” is reserved for images."
        case .imageTooLarge(let bytes, let limit):
            return "That image is \(Self.megabytes(bytes)), and the limit is \(Self.megabytes(limit))."
        case .unsupportedImageType(let name):
            return "“\(name)” is not an image format this editor can insert."
        case .documentTooLarge(let bytes, let limit):
            return "This document is \(Self.megabytes(bytes)), and the limit is \(Self.megabytes(limit))."
        case .notSignedIn:
            return "You are not signed in."
        case .signInFailed(let reason):
            return "Sign-in did not finish. \(reason)"
        case .signInCancelled:
            return "Sign-in was cancelled."
        case .offline(let doing):
            return "The editor could not reach your cloud workspace while trying to \(doing)."
        case .storageUnavailable(let doing):
            return "Could not \(doing)."
        case .permissionDenied(let doing):
            return "Your account is not allowed to \(doing)."
        case .underlying(let message):
            return message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .alreadyExists:
            return "Choose a different name."
        case .imageTooLarge:
            return "Scale the image down and try again."
        case .unsupportedImageType:
            return "Use a PNG, JPEG, GIF, HEIC, TIFF, BMP, WebP, or SVG file."
        case .documentTooLarge:
            return "Firestore stores a document in a single record, which is capped at 1 MB. Split this into smaller documents."
        case .notSignedIn:
            return "Connect a Google account to use cloud documents."
        case .signInFailed:
            return "Check that the Google sign-in provider is enabled for this Firebase project, then try again."
        case .permissionDenied:
            return "Publish the rules in Web/firebase/, and check that the account owns this document."
        case .offline:
            return "Check your network connection and try again. Documents you have already opened on this device stay available."
        case .storageUnavailable:
            return "Check that Cloud Storage is enabled for this Firebase project, then try again."
        case .cannotMoveIntoItself:
            return "Choose a folder that is not inside it."
        case .reservedAssetsFolder:
            return "Rename the document instead."
        default:
            return nil
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
