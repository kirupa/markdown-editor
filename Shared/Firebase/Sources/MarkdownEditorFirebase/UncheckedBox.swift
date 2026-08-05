/// Carries a Firebase handle across a concurrency boundary.
///
/// Several Firebase types — `ListenerRegistration`, the auth-state handle — are
/// documented as safe to use from any thread but are not annotated `Sendable`.
/// Swift 6 then refuses to let them cross into a `@Sendable` closure or out of
/// an isolated class into `deinit`, even to call the one method that detaches
/// them. This box is the narrow, deliberate exception, kept in one place so
/// every use of it is visible at once rather than scattered as `@unchecked`
/// annotations on real types.
final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
