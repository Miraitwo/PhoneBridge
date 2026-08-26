import AppKit
import SwiftUI

struct MacDropReceiver<Content: View>: NSViewRepresentable {
    let typeIdentifier: String
    let onTargeted: (Bool) -> Void
    let onData: (Data) -> Bool
    let content: Content

    init(
        typeIdentifier: String,
        onTargeted: @escaping (Bool) -> Void,
        onData: @escaping (Data) -> Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.typeIdentifier = typeIdentifier
        self.onTargeted = onTargeted
        self.onData = onData
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NativeDropView {
        let view = NativeDropView()
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        context.coordinator.hostingView = hostingView
        view.configure(
            typeIdentifier: typeIdentifier,
            onTargeted: onTargeted,
            onData: onData
        )
        return view
    }

    func updateNSView(_ view: NativeDropView, context: Context) {
        context.coordinator.hostingView?.rootView = content
        view.configure(
            typeIdentifier: typeIdentifier,
            onTargeted: onTargeted,
            onData: onData
        )
    }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }
}

final class NativeDropView: NSView {
    private var acceptedType = NSPasteboard.PasteboardType(RemoteDragCodec.typeIdentifier)
    private var onTargeted: (Bool) -> Void = { _ in }
    private var onData: (Data) -> Bool = { _ in false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([acceptedType])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([acceptedType])
    }

    func configure(
        typeIdentifier: String,
        onTargeted: @escaping (Bool) -> Void,
        onData: @escaping (Data) -> Bool
    ) {
        let nextType = NSPasteboard.PasteboardType(typeIdentifier)
        if nextType != acceptedType {
            unregisterDraggedTypes()
            acceptedType = nextType
            registerForDraggedTypes([acceptedType])
        }
        self.onTargeted = onTargeted
        self.onData = onData
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [acceptedType]) != nil else {
            return []
        }
        onTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [acceptedType]) != nil else {
            onTargeted(false)
            return []
        }
        onTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: [acceptedType]) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onTargeted(false) }
        guard let data = sender.draggingPasteboard.data(forType: acceptedType) else {
            return false
        }
        return onData(data)
    }
}
