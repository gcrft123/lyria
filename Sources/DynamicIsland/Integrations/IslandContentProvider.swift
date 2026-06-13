import Foundation

/// A source of content that can present itself on the island.
///
/// This is the common contract behind the notification feed, the music
/// player, and any future integration. A provider is registered with the
/// `DynamicIslandController`, keeps a reference back to it, and (once its
/// integration is built) drives the island by calling `controller.transition`.
///
/// Nothing implements the *presentation* side yet — these are the seams the
/// later features hang off of.
@MainActor
protocol IslandContentProvider: AnyObject {

    /// Stable identifier, used to prevent duplicate registration.
    var id: String { get }

    /// Called once when the provider is registered. Capture the controller
    /// here; do not retain it strongly elsewhere.
    func didRegister(with controller: DynamicIslandController)

    /// Begin observing the underlying system source (notifications, now
    /// playing info, …). Default is a no-op until the integration is built.
    func startObserving()

    /// Stop observing and release any system resources.
    func stopObserving()
}

extension IslandContentProvider {
    func startObserving() {}
    func stopObserving() {}
}
