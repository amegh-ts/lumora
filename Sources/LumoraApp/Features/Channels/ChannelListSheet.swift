import AppKit
import UniformTypeIdentifiers

/// "Add a Channel List" sheet: iptv-org presets, a link, or a file. Also rename and remove.
@MainActor
enum ChannelListSheet {
    static func presentAdd(on window: NSWindow, store: ChannelStore = .shared, added: @escaping (UUID) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Add a Channel List"
        alert.informativeText = "Pick a free list from iptv-org, or paste the M3U link from your TV provider."
        alert.icon = NSImage(systemSymbolName: "tv.and.mediabox", accessibilityDescription: nil)

        let options = ChannelStore.presets.map(\.name) + ["Link from my provider…"]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: options)
        let field = NSTextField()
        field.placeholderString = "https://provider.example/channels.m3u"
        field.isHidden = true
        let fileButton = NSButton(title: "Use a File on This Mac…", target: nil, action: nil)
        fileButton.bezelStyle = .inline
        fileButton.controlSize = .small
        let stack = NSStackView(views: [popup, field, fileButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [popup, field] {
            view.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 90)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let actions = SheetActions()
        actions.onChoice = { index in
            let custom = index == ChannelStore.presets.count
            field.isHidden = !custom
            if custom {
                field.window?.makeFirstResponder(field)
            }
        }
        actions.onFile = { [weak window] in
            guard let window else { return }
            window.endSheet(alert.window, returnCode: .cancel)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType.m3uPlaylist, UTType(filenameExtension: "m3u8")].compactMap { $0 }
            panel.allowsOtherFileTypes = true
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { added(store.addSource(url: url)) }
            }
        }
        popup.target = actions
        popup.action = #selector(SheetActions.choiceChanged(_:))
        fileButton.target = actions
        fileButton.action = #selector(SheetActions.chooseFile(_:))

        alert.beginSheetModal(for: window) { response in
            _ = actions
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                let index = popup.indexOfSelectedItem
                if index < ChannelStore.presets.count, let url = URL(string: ChannelStore.presets[index].url) {
                    let name = ChannelStore.presets[index].name.replacingOccurrences(of: " (iptv-org)", with: "")
                    added(store.addSource(url: url, name: index == 0 ? "iptv-org" : name))
                } else if let url = MainWindowController.normalizedLink(field.stringValue.trimmingCharacters(in: .whitespaces)) {
                    added(store.addSource(url: url))
                } else {
                    let warning = NSAlert()
                    warning.messageText = "That link doesn't look right"
                    warning.informativeText = "Paste the full link to the M3U list, starting with https://."
                    warning.beginSheetModal(for: window)
                }
            }
        }
    }

    static func presentRename(on window: NSWindow, source: ChannelSource, store: ChannelStore = .shared) {
        let alert = NSAlert()
        alert.messageText = "Rename List"
        let field = NSTextField(string: source.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { store.rename(source.id, to: field.stringValue.trimmingCharacters(in: .whitespaces)) }
        }
    }

    static func presentRemove(on window: NSWindow, source: ChannelSource, store: ChannelStore = .shared) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(source.name)”?"
        alert.informativeText = "Its channels disappear from Live TV. Your favourites come back if you add the list again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { store.removeSource(source.id) }
        }
    }
}

@MainActor
private final class SheetActions: NSObject {
    var onChoice: ((Int) -> Void)?
    var onFile: (() -> Void)?

    @objc func choiceChanged(_ sender: NSPopUpButton) {
        onChoice?(sender.indexOfSelectedItem)
    }

    @objc func chooseFile(_ sender: Any?) {
        onFile?()
    }
}
