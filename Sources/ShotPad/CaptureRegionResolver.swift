import AppKit
import ApplicationServices
import Vision
import ShotPadCore

/// Only frames are retained; no text, values, browser URLs or content are read.
final class CaptureRegionResolver {
    private let queue = DispatchQueue(label: "Hoot.CaptureHitTest", qos: .userInteractive)
    private var pending: DispatchWorkItem?
    func cancel() { pending?.cancel(); pending = nil }
    deinit { pending?.cancel() }

    func query(point: CGPoint, ownerPID: Int32, completion: @escaping ([CGRect]) -> Void) {
        pending?.cancel()
        guard ownerPID != getpid(), ownerPID > 0, AXIsProcessTrusted() else { completion([]); return }
        let item = DispatchWorkItem {
            let result = Self.accessibilityRegions(at: point, pid: ownerPID)
            DispatchQueue.main.async { completion(result) }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.045, execute: item)
    }

    private static func accessibilityRegions(at point: CGPoint, pid: Int32) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.07)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return [] }
        let deadline = Date().addingTimeInterval(0.16)
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute] as CFArray
        var result: [CGRect] = []
        for _ in 0..<16 {
            if Date() > deadline { break }
            AXUIElementSetMessagingTimeout(element, 0.025)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, [], &raw) == .success,
                  let values = raw as? [Any], values.count == 3 else { break }
            var origin = CGPoint.zero, size = CGSize.zero
            if CFGetTypeID(values[0] as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID() {
                let position = values[0] as! AXValue, extent = values[1] as! AXValue
                if AXValueGetType(position) == .cgPoint, AXValueGetType(extent) == .cgSize,
                   AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(extent, .cgSize, &size), size.width >= 10, size.height >= 10 {
                    result.append(CGRect(origin: origin, size: size))
                }
            }
            guard CFGetTypeID(values[2] as CFTypeRef) == AXUIElementGetTypeID() else { break }
            let parent = values[2] as! AXUIElement
            if CFEqual(parent, element) { break }; element = parent
        }
        return result
    }

    /// Snapshot Hoot's own exposed views before overlays are created. This does not
    /// require granting Hoot access to other applications' accessibility trees.
    @MainActor static func ownRegions() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let deadline = Date().addingTimeInterval(0.035)
        var result: [CGRect] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, depth: Int) {
            guard depth < 28, result.count < 1200, Date() < deadline,
                  let node = object as? NSAccessibilityProtocol else { return }
            let key = ObjectIdentifier(node)
            guard seen.insert(key).inserted else { return }
            let r = node.accessibilityFrame()
            if r.width >= 10, r.height >= 10 { result.append(CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)) }
            for child in node.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
        }
        for window in NSApp.windows where window.isVisible && window.level.rawValue < Int(CGShieldingWindowLevel()) { visit(window, depth: 0) }
        return result
    }

}
