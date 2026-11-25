import MapKit
import UIKit

/// Reports "the user is driving the camera" without touching MapKit's gestures.
///
/// MapKit has no delegate callback for pan/pinch begin/end, and hooking its
/// internal recognizers is fragile: those are created lazily, their identities
/// change, and a mistaken `isEnabled` write breaks map interaction outright.
///
/// These recognizers are added alongside and configured to recognise
/// simultaneously with everything else, so they only *observe* — they never
/// cancel, delay, or win against the map's own handling.
final class CameraGestureObserver: NSObject, UIGestureRecognizerDelegate {
    private let onBegan: () -> Void
    private let onEnded: () -> Void
    private var activeGestures = 0

    init(onBegan: @escaping () -> Void, onEnded: @escaping () -> Void) {
        self.onBegan = onBegan
        self.onEnded = onEnded
    }

    func makeRecognizers() -> [UIGestureRecognizer] {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.minimumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handle(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false

        return [pan, pinch]
    }

    @objc private func handle(_ recognizer: UIGestureRecognizer) {
        switch recognizer.state {
        case .began:
            activeGestures += 1
            if activeGestures == 1 {
                onBegan()
            }
        case .ended, .cancelled, .failed:
            // Pinch and pan can overlap; only report the end once both are gone.
            activeGestures = max(0, activeGestures - 1)
            if activeGestures == 0 {
                onEnded()
            }
        default:
            break
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Never compete with the map: recognise in parallel, so the observer is
    /// purely additive.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Only claim touches that are headed for the map itself, so tapping an
    /// overlay button does not count as camera interaction.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let mapView = gestureRecognizer.view as? MKMapView, let view = touch.view else {
            return false
        }
        return view === mapView || view.isDescendant(of: mapView)
    }
}
