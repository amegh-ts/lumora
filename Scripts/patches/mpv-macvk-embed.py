#!/usr/bin/env python3
"""Let mpv's macOS Vulkan/Metal output (gpu-context=macvk) render into a host NSView.

Upstream mpv always creates its own window for macvk. With this patch, setting the `wid` option
to the address of an NSView makes mpv add its CAMetalLayer to that view instead, follow the view's
size, scale and screen, and skip window, app-icon and activation-policy setup. That lets libmpv
embedders use vo=gpu-next (libplacebo, HDR/EDR) instead of the OpenGL render API.

It also stops rendering while the host window is fully hidden (occluded or minimized).

Usage: mpv-macvk-embed.py <mpv source dir>
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def patch(relative, replacements):
    path = root / relative
    text = path.read_text()
    for old, new in replacements:
        if text.count(old) != 1:
            sys.exit(f"patch failed: {relative}: expected one match for {old[:60]!r}")
        text = text.replace(old, new)
    path.write_text(text)


patch("video/out/mac_common.swift", [
    (
        "    let swapLock: NSCondition = NSCondition()\n",
        "    let swapLock: NSCondition = NSCondition()\n"
        "    var embedView: NSView?\n"
        "    var embedObservers: [NSObjectProtocol] = []\n"
        "    var embedVisible: Bool = true\n",
    ),
    (
        "        DispatchQueue.main.sync {\n"
        "            let previousActiveApp = getActiveApp()\n",
        "        DispatchQueue.main.sync {\n"
        "            if embedView == nil, option.vo.WinID > 0, let layer = self.layer,\n"
        "               let pointer = UnsafeMutableRawPointer(bitPattern: Int(option.vo.WinID)) {\n"
        "                embed(layer, in: Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue())\n"
        "            }\n"
        "            if embedView != nil {\n"
        "                embeddedFrameChanged()\n"
        "                updateICCProfile()\n"
        "                return\n"
        "            }\n"
        "            let previousActiveApp = getActiveApp()\n",
    ),
    (
        "        DispatchQueue.main.sync {\n"
        "            window?.delegate = nil\n",
        "        DispatchQueue.main.sync {\n"
        "            embedObservers.forEach { NotificationCenter.default.removeObserver($0) }\n"
        "            embedObservers = []\n"
        "            layer?.removeFromSuperlayer()\n"
        "            embedView = nil\n"
        "            window?.delegate = nil\n",
    ),
    (
        "    @objc func isVisible() -> Bool {\n",
        "    @objc func isVisible() -> Bool {\n"
        "        if embedView != nil { return embedVisible || needsInitialDraw || option.vo.force_render }\n",
    ),
    (
        "    override func updateICCProfile() {\n",
        "    func embed(_ layer: MetalLayer, in host: NSView) {\n"
        "        embedView = host\n"
        "        host.wantsLayer = true\n"
        "        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]\n"
        "        host.layer?.addSublayer(layer)\n"
        "        host.postsFrameChangedNotifications = true\n"
        "        let center = NotificationCenter.default\n"
        "        embedObservers.append(center.addObserver(forName: NSView.frameDidChangeNotification,\n"
        "                                                 object: host, queue: .main) { [weak self] _ in\n"
        "            self?.embeddedFrameChanged()\n"
        "        })\n"
        "        embedObservers.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification,\n"
        "                                                 object: nil, queue: .main) { [weak self] note in\n"
        "            guard let self, let window = note.object as? NSWindow, window == self.embedView?.window else { return }\n"
        "            self.embeddedFrameChanged()\n"
        "        })\n"
        "        embedVisible = host.window?.occlusionState.contains(.visible) ?? true\n"
        "        embedObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,\n"
        "                                                 object: nil, queue: .main) { [weak self] note in\n"
        "            guard let self, let window = note.object as? NSWindow, window == self.embedView?.window else { return }\n"
        "            self.embedVisible = window.occlusionState.contains(.visible)\n"
        "            self.flagEvents(VO_EVENT_EXPOSE)\n"
        "        })\n"
        "        embedObservers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification,\n"
        "                                                 object: nil, queue: .main) { [weak self] note in\n"
        "            guard let self, let window = note.object as? NSWindow, window == self.embedView?.window,\n"
        "                  let screen = window.screen else { return }\n"
        "            if let link = self.link { CVDisplayLinkSetCurrentCGDisplay(link, screen.displayID) }\n"
        "            self.updateICCProfile()\n"
        "        })\n"
        "    }\n"
        "\n"
        "    func embeddedFrameChanged() {\n"
        "        guard let host = embedView, let layer = self.layer else { return }\n"
        "        CATransaction.begin()\n"
        "        CATransaction.setDisableActions(true)\n"
        "        layer.frame = host.bounds\n"
        "        layer.contentsScale = host.window?.backingScaleFactor ?? layer.contentsScale\n"
        "        CATransaction.commit()\n"
        "        windowDidResize()\n"
        "    }\n"
        "\n"
        "    override func getCurrentScreen() -> NSScreen? {\n"
        "        return embedView?.window?.screen ?? super.getCurrentScreen()\n"
        "    }\n"
        "\n"
        "    override func updateICCProfile() {\n",
    ),
])

patch("video/out/vulkan/context_mac.m", [
    (
        "    if (!p->vo_mac.window) {\n"
        "        return false;\n"
        "    }\n"
        "    CGSize size = p->vo_mac.window.framePixel.size;\n",
        "    CGSize size;\n"
        "    if (p->vo_mac.window) {\n"
        "        size = p->vo_mac.window.framePixel.size;\n"
        "    } else if (p->vo_mac.layer) {\n"
        "        CGRect bounds = p->vo_mac.layer.bounds;\n"
        "        CGFloat scale = p->vo_mac.layer.contentsScale;\n"
        "        size = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);\n"
        "    } else {\n"
        "        return false;\n"
        "    }\n",
    ),
])

print("mpv macvk embed patch applied")
