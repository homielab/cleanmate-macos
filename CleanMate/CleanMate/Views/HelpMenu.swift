import AppKit
import SwiftUI

/// Help menu: the welcome guide, report a bug or suggest a feature on GitHub, open the repository, copy the website
/// link to share. The GitHub items only open the browser or copy text: CleanMate itself sends nothing.
struct HelpCommands: Commands {
    @FocusedValue(\.confirming) private var confirming

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Getting Started…") { ModuleRouter.shared.showWelcome() }
                .disabled(confirming == true)
            Divider()
            Button("Report a Bug…") { BugReportPreview.show() }
            Button("Suggest a Feature…") {
                NSWorkspace.shared.open(ProjectLinks.newIssue(template: BugReport.featureTemplate))
            }
            Divider()
            Button("CleanMate on GitHub") { NSWorkspace.shared.open(ProjectLinks.repository) }
                .help("Give CleanMate a Star on GitHub so more people find it")
            Button("Share CleanMate") {
                Pasteboard.copy(ProjectLinks.website.absoluteString)
                Toast.show(String(localized: "Link copied: \(ProjectLinks.website.host() ?? "")"))
            }
        }
    }
}

/// "Report a Bug…": shows the report text before anything opens; Open GitHub, Copy or Cancel.
@MainActor enum BugReportPreview {
    static func show(_ report: BugReport = .current()) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Report a Bug")
        alert.informativeText = String(localized: "Open GitHub opens a new issue in your browser with the details below filled in; describe the problem there. Nothing is sent until you submit the issue, and no user name or personal file path is included.")
        alert.accessoryView = textView(report.body)
        alert.addButton(withTitle: String(localized: "Open GitHub"))
        alert.addButton(withTitle: String(localized: "Copy"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[2].keyEquivalent = "\u{1b}" // Esc whatever the language: NSAlert only knows an English "Cancel"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: open(report)
            case .alertSecondButtonReturn:
                Pasteboard.copy(report.body)
                Toast.show(String(localized: "Report copied"))
            default: break
            }
        }
        // A sheet on the main window when it is free; with the window closed or a confirmation open, its own window.
        NSApp.activate(ignoringOtherApps: true)
        if let window = ModuleRouter.mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Opens the prefilled issue; a report too long for the link is copied first, and the user is told to paste it.
    static func open(_ report: BugReport) {
        if !report.fitsLink {
            Pasteboard.copy(report.body)
            let notice = NSAlert()
            notice.messageText = String(localized: "Report copied")
            notice.informativeText = String(localized: "The details are too long for the link. Paste them into “System details” on the GitHub page.")
            notice.addButton(withTitle: String(localized: "Open GitHub"))
            notice.runModal()
        }
        NSWorkspace.shared.open(report.issueURL)
    }

    /// The report, read-only but selectable, in a scroll view.
    private static func textView(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 200)
        scroll.borderType = .bezelBorder
        scroll.hasHorizontalScroller = false
        if let view = scroll.documentView as? NSTextView {
            view.string = text
            view.isEditable = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            view.textContainerInset = NSSize(width: 4, height: 6)
            view.setAccessibilityLabel(String(localized: "Report details"))
        }
        return scroll
    }
}

@MainActor enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A short message near the bottom of the active window (or the screen) that fades out; also read by VoiceOver.
@MainActor enum Toast {
    private static var panel: NSPanel?
    static let duration: TimeInterval = 2

    static func show(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        let size = NSSize(width: label.fittingSize.width + 36, height: label.fittingSize.height + 20)
        let toast = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = true
        toast.level = .floating
        toast.ignoresMouseEvents = true
        toast.isReleasedWhenClosed = false
        toast.collectionBehavior = [.canJoinAllSpaces, .transient]
        toast.contentView = background
        let window = [NSApp.keyWindow, ModuleRouter.mainWindow].compactMap { $0 }.first { $0.isVisible }
        if let area = window?.frame ?? NSScreen.main?.visibleFrame {
            toast.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 48))
        }
        toast.orderFrontRegardless()
        panel = toast
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; toast.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    toast.orderOut(nil)
                    if panel === toast { panel = nil }
                }
            }
        }
    }
}
