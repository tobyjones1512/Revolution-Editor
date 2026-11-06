import SwiftUI
import Combine
import AppKit

/// Shared handles between the text view and its minimap.
@MainActor final class EditorBridge: ObservableObject {
	weak var textView: NSTextView?
	weak var scrollView: NSScrollView?
	var onContentChanged: (() -> Void)?
	var onScrolled: (() -> Void)?
	private var observer: NSObjectProtocol?

	func attach(textView: NSTextView, scrollView: NSScrollView) {
		self.textView = textView
		self.scrollView = scrollView
		scrollView.contentView.postsBoundsChangedNotifications = true
		observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.onScrolled?() }
		}
	}
	func contentChanged() { onContentChanged?() }
}

struct MinimapRepresentable: NSViewRepresentable {
	let bridge: EditorBridge
	func makeNSView(context: Context) -> MinimapView { MinimapView(bridge: bridge) }
	func updateNSView(_ nsView: MinimapView, context: Context) { nsView.needsDisplay = true }
}

/// A zoomed-out picture of the whole file in its syntax colours, with the visible part outlined. Click or drag to scroll.
final class MinimapView: NSView {
	private let bridge: EditorBridge
	private var image: NSImage?
	private var imageStale = true
	private let lineHeight: CGFloat = 2.4, charWidth: CGFloat = 1.1, maxLines = 4000

	init(bridge: EditorBridge) {
		self.bridge = bridge
		super.init(frame: .zero)
		bridge.onContentChanged = { [weak self] in self?.imageStale = true; self?.needsDisplay = true }
		bridge.onScrolled = { [weak self] in self?.needsDisplay = true }
	}
	required init?(coder: NSCoder) { fatalError() }
	override var isFlipped: Bool { true }

	/// Paints each line's runs as thin bars, once per content change.
	private func renderImage() -> NSImage? {
		guard let storage = bridge.textView?.textStorage, storage.length > 0 else { return nil }
		let text = storage.string as NSString
		var lineStarts: [Int] = [0]
		var i = 0
		while i < text.length, lineStarts.count < maxLines { if text.character(at: i) == 10 { lineStarts.append(i + 1) }; i += 1 }
		let size = NSSize(width: max(bounds.width, 1), height: CGFloat(lineStarts.count) * lineHeight)
		let image = NSImage(size: size, flipped: true) { _ in
			let tab = CGFloat(CodeEditorPrefs.shared.tabWidth)
			for (n, start) in lineStarts.enumerated() {
				let end = n + 1 < lineStarts.count ? lineStarts[n + 1] - 1 : text.length
				guard end > start else { continue }
				var x: CGFloat = 4
				var j = start
				while j < end, x < size.width - 2 {
					let c = text.character(at: j)
					if c == 32 { x += self.charWidth; j += 1; continue }
					if c == 9 { x += self.charWidth * tab; j += 1; continue }
					var range = NSRange()
					let color = (storage.attribute(.foregroundColor, at: j, effectiveRange: &range) as? NSColor) ?? .labelColor
					let runEnd = min(NSMaxRange(range), end)
					var k = j
					while k < runEnd, text.character(at: k) != 32, text.character(at: k) != 9 { k += 1 }
					color.withAlphaComponent(0.75).setFill()
					NSRect(x: x, y: CGFloat(n) * self.lineHeight, width: CGFloat(k - j) * self.charWidth, height: self.lineHeight - 0.8).fill()
					x += CGFloat(k - j) * self.charWidth
					j = k
				}
			}
			return true
		}
		return image
	}

	/// How far the minimap itself is scrolled, when the file is taller than the view.
	private func offset(contentHeight: CGFloat, scrollFraction: CGFloat) -> CGFloat {
		contentHeight > bounds.height ? scrollFraction * (contentHeight - bounds.height) : 0
	}

	private var metrics: (docHeight: CGFloat, visible: NSRect)? {
		guard let sv = bridge.scrollView, let doc = sv.documentView else { return nil }
		return (doc.bounds.height, sv.contentView.bounds)
	}

	override func draw(_ dirtyRect: NSRect) {
		CodeTheme.backgroundOrSystem.setFill()
		bounds.fill()
		CodeTheme.gutter.withAlphaComponent(0.5).setFill()
		bounds.fill()
		if imageStale || image == nil { image = renderImage(); imageStale = false }
		guard let image, let (docHeight, visible) = metrics, docHeight > 0 else { return }
		let denominator = max(docHeight - visible.height, 1)
		let off = offset(contentHeight: image.size.height, scrollFraction: min(max(visible.minY / denominator, 0), 1))
		image.draw(in: NSRect(x: 0, y: -off, width: bounds.width, height: image.size.height))
		// The visible window.
		let scale = image.size.height / docHeight
		let box = NSRect(x: 0, y: visible.minY * scale - off, width: bounds.width, height: max(visible.height * scale, 8))
		NSColor.labelColor.withAlphaComponent(0.10).setFill()
		box.fill()
	}

	private func scroll(to point: NSPoint) {
		guard let sv = bridge.scrollView, let (docHeight, visible) = metrics, let image else { return }
		let denominator = max(docHeight - visible.height, 1)
		let off = offset(contentHeight: image.size.height, scrollFraction: min(max(visible.minY / denominator, 0), 1))
		let docY = (point.y + off) / max(image.size.height, 1) * docHeight - visible.height / 2
		sv.contentView.scroll(to: NSPoint(x: 0, y: min(max(docY, 0), denominator)))
		sv.reflectScrolledClipView(sv.contentView)
	}

	override func mouseDown(with event: NSEvent) { scroll(to: convert(event.locationInWindow, from: nil)) }
	override func mouseDragged(with event: NSEvent) { scroll(to: convert(event.locationInWindow, from: nil)) }
}
