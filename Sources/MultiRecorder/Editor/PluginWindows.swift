import AVFoundation
import AppKit
import CoreAudioKit
import SwiftUI

/// A panel that stays above the editor, so clicks in the editor do not hide it.
private func makeFloatingPanel(_ controller: NSViewController, title: String, utility: Bool) -> NSPanel {
    var style: NSWindow.StyleMask = [.titled, .closable]
    if utility { style.insert(.utilityWindow) }
    let panel = NSPanel(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
    panel.contentViewController = controller
    panel.title = title
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = true
    panel.isReleasedWhenClosed = false
    // Tool panels have no text field: keep the editor key so Space and L still work.
    panel.becomesKeyOnlyIfNeeded = utility
    return panel
}

/// SwiftUI tool panels (effect chain, picture settings), one per key.
@MainActor
final class ToolPanels: NSObject, NSWindowDelegate {
    private var panels: [String: NSPanel] = [:]

    func toggle(_ key: String, title: String, content: () -> some View) {
        if let panel = panels[key] {
            panel.close()
            return
        }
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = [.preferredContentSize]
        let panel = makeFloatingPanel(controller, title: title, utility: true)
        panel.delegate = self
        panels[key] = panel
        if let main = NSApp.keyWindow {
            // Open next to the editor window when there is room.
            let size = controller.view.fittingSize
            let origin = NSPoint(x: main.frame.maxX - size.width - 20, y: main.frame.maxY - size.height - 60)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.orderFront(nil)
    }

    func isOpen(_ key: String) -> Bool {
        panels[key] != nil
    }

    func closeAll() {
        for panel in panels.values {
            panel.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let key = panels.first(where: { $0.value === window })?.key
        else { return }
        panels[key] = nil
    }
}

/// One window per open effect, showing the plug-in's own interface.
@MainActor
final class PluginWindows: NSObject, NSWindowDelegate {
    var onClose: ((UUID) -> Void)?
    private var windows: [UUID: NSWindow] = [:]

    func open(effectID: UUID, unit: AVAudioUnit, title: String) {
        if let window = windows[effectID] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        unit.auAudioUnit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let content = controller ?? Self.fallbackController(for: unit)
                    self?.show(content, effectID: effectID, title: title)
                }
            }
        }
    }

    func close(_ effectID: UUID) {
        windows[effectID]?.close()
    }

    func closeAll() {
        for window in windows.values {
            window.close()
        }
    }

    private func show(_ controller: NSViewController, effectID: UUID, title: String) {
        guard windows[effectID] == nil else { return }
        var size = controller.preferredContentSize
        if size.width < 10 || size.height < 10 {
            size = controller.view.frame.size
        }
        if size.width < 10 || size.height < 10 {
            size = NSSize(width: 480, height: 320)
        }

        let window = makeFloatingPanel(controller, title: title, utility: false)
        window.setContentSize(size)
        window.delegate = self
        window.center()
        windows[effectID] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windows.first(where: { $0.value === window })?.key
        else { return }
        windows[id] = nil
        onClose?(id)
    }

    /// Audio Unit v2 interface (Cocoa view), else a generic parameter view.
    private static func fallbackController(for unit: AVAudioUnit) -> NSViewController {
        let controller = NSViewController()
        if let view = cocoaView(for: unit.audioUnit) {
            controller.view = view
        } else {
            let view = AUGenericView(audioUnit: unit.audioUnit)
            view.showsExpertParameters = true
            controller.view = view
        }
        return controller
    }

    private static func cocoaView(for audioUnit: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard
            AudioUnitGetPropertyInfo(
                audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
            size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size)
        else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        guard
            AudioUnitGetProperty(audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size)
                == noErr
        else { return nil }

        let info = raw.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
        let bundleURL = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard let bundle = Bundle(url: bundleURL), bundle.load(),
            let factoryClass = bundle.classNamed(className) as? NSObject.Type
        else { return nil }

        // The factory follows the AUCocoaUIBase protocol, which Swift does not import.
        let factory = factoryClass.init()
        let selector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard factory.responds(to: selector) else { return nil }
        typealias MakeView = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> Unmanaged<NSView>?
        let makeView = unsafeBitCast(factory.method(for: selector), to: MakeView.self)
        return makeView(factory, selector, audioUnit, NSSize(width: 480, height: 320))?.takeUnretainedValue()
    }
}
