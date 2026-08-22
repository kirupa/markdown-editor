import Foundation

/// Watches one file and says when something else has written it.
///
/// Shared by both apps: kqueue is BSD, so the same source works on macOS and
/// iOS, and the interesting behaviour — surviving an atomic save — is
/// identical on each.
///
/// **Atomic saves are the whole difficulty.** Almost nothing writes a file in
/// place. TextEdit, Xcode, `git`, BBEdit and the shell's own `mv` all write a
/// temporary file and rename it over the target, which is what makes a save
/// crash-safe. The consequence here is that the file this monitor has open is
/// not the file at that path any more: the descriptor still refers to the old
/// inode, which is now unlinked, and it will never see another write. A
/// monitor that ignores this reports the first external save and then goes
/// quiet forever — worse than not existing, because it looks like it works.
///
/// So `.rename` and `.delete` are watched alongside `.write`, and either one
/// tears the source down and re-arms on the path. The re-arm has to tolerate a
/// gap: between the unlink and the rename there is a moment when the path
/// resolves to nothing, and opening it fails with `ENOENT` through no fault of
/// anybody's. `retryDelay` covers that window, and repeated failures back off
/// rather than spin.
///
/// `@unchecked Sendable` because every mutable property below is touched only
/// on `queue`, a private serial queue, and the compiler cannot see that. The
/// two exceptions are `init`, which runs before anything can reach the
/// instance, and `deinit`, which runs after everything has let go of it.
public final class FileChangeMonitor: @unchecked Sendable {
    /// How long to wait for a burst of writes to settle before looking.
    ///
    /// A single logical save can be several `write` events — truncate, write,
    /// extend — and reading the file between two of them sees a half-written
    /// document. Waiting for quiet is both cheaper and more accurate than
    /// reading three times.
    private static let settleDelay: DispatchTimeInterval = .milliseconds(150)

    /// How long to wait before re-opening a path that has just vanished.
    private static let retryDelay: DispatchTimeInterval = .milliseconds(80)

    /// How many times to keep retrying a vanished path before giving up.
    ///
    /// A rename window is measured in milliseconds; a file that is still gone
    /// after this many tries was deleted rather than replaced, and there is
    /// nothing left to watch.
    private static let maximumRetries = 12

    private let url: URL
    private let queue = DispatchQueue(
        label: "com.kirupa.markdown-editor.file-monitor"
    )
    private let onChange: @Sendable () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var settleWorkItem: DispatchWorkItem?
    private var retries = 0
    private var isCancelled = false

    /// - Parameter onChange: called on the main queue, already debounced, once
    ///   the file has stopped being written to. It says *something happened*,
    ///   not *what*: deciding whether the new contents are news is
    ///   ``ExternalDocumentChange``'s job, and keeping the two apart is what
    ///   lets the decision be tested without a file system.
    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
        queue.async { [weak self] in
            self?.arm()
        }
    }

    deinit {
        // Not `queue.async`: `self` is already going away, so the descriptor
        // has to be released here and now.
        source?.cancel()
        if source == nil, descriptor >= 0 {
            close(descriptor)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.settleWorkItem?.cancel()
            self.settleWorkItem = nil
            self.teardown()
        }
    }

    private func arm() {
        guard !isCancelled else { return }
        teardown()

        let opened = open(url.path, O_EVTONLY)
        guard opened >= 0 else {
            scheduleRetry()
            return
        }

        retries = 0
        descriptor = opened
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: opened,
            // `.extend` as well as `.write`: appending to a file — `>>` from a
            // shell, a log being written — reports only the size change.
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let event = source.data
            if event.contains(.rename)
                || event.contains(.delete)
                || event.contains(.revoke)
            {
                // The path has been replaced or removed. Follow the path
                // rather than the inode, then report: an atomic save is a
                // rename, and it is exactly the change worth hearing about.
                self.arm()
                self.scheduleNotification()
            } else {
                self.scheduleNotification()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else {
                close(opened)
                return
            }
            close(opened)
            if self.descriptor == opened {
                self.descriptor = -1
            }
        }

        self.source = source
        source.resume()
    }

    private func scheduleRetry() {
        guard !isCancelled, retries < Self.maximumRetries else { return }
        retries += 1
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            self?.arm()
        }
    }

    private func scheduleNotification() {
        guard !isCancelled else { return }
        settleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            let onChange = self.onChange
            DispatchQueue.main.async {
                onChange()
            }
        }
        settleWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func teardown() {
        if let source {
            // Cancelling closes the descriptor through the cancel handler;
            // closing it here as well would risk closing a descriptor the
            // system has already handed to somebody else.
            source.cancel()
            self.source = nil
        } else if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }
}
