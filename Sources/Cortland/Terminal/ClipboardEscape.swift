import AppKit
import SwiftTerm

/// OSC 52: the program inside a pane asks the terminal to put text on the
/// system clipboard.
///
///     ESC ] 52 ; Pc ; Pd BEL        (or ST in place of BEL)
///
/// `Pc` names the X selections to set (any of `c p q s 0-7`, empty meaning
/// `s0`); `Pd` is the base64 payload, or `?` to read the clipboard back.
/// tmux's copy mode, Neovim's clipboard provider, Helix, Zellij, and the
/// agent CLIs all copy this way, because a terminal-side mouse selection of
/// their output picks up wrapped line breaks, pane borders, and padding that
/// the text never had.
///
/// SwiftTerm parses the sequence and calls its `Terminal`-level
/// `clipboardCopy` delegate method, but its macOS view never implements that
/// method (only the view-level one, which nothing reaches), so the request
/// dies in a protocol-extension no-op. A handler registered on the terminal
/// runs ahead of SwiftTerm's own dispatch, which is how Cortland takes it over.
nonisolated enum ClipboardEscape {
    /// Routes every OSC 52 write on `terminal` to `pasteboard`.
    static func install(on terminal: Terminal, pasteboard: NSPasteboard = .general) {
        terminal.registerOscHandler(code: 52) { data in
            guard let text = copyText(from: data) else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// The text an OSC 52 parameter string (`Pc ; Pd`) asks to put on the
    /// clipboard, or nil when there is nothing to copy: a `?` query (never
    /// answered; a program must not be able to read the clipboard through the
    /// PTY), a malformed selector, an empty payload, or bytes that aren't
    /// base64.
    ///
    /// macOS has one clipboard, so every selection in `Pc` lands on the general
    /// pasteboard. The payload tolerates the line wrapping and missing padding
    /// some encoders produce, and invalid UTF-8 decodes lossily rather than
    /// dropping the copy.
    static func copyText(from data: ArraySlice<UInt8>) -> String? {
        guard let separator = data.firstIndex(of: UInt8(ascii: ";")) else { return nil }
        let selector = data[data.startIndex..<separator]
        guard selector.allSatisfy({ selectorCharacters.contains($0) }) else { return nil }

        let payload = data[(separator + 1)...]
        guard !payload.isEmpty, payload != [UInt8(ascii: "?")][...] else { return nil }

        var base64 = payload.filter { !whitespace.contains($0) }
        guard !base64.isEmpty else { return nil }
        while base64.count % 4 != 0 { base64.append(UInt8(ascii: "=")) }
        guard let decoded = Data(base64Encoded: Data(base64)) else { return nil }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static let selectorCharacters = Set("cpqs01234567".utf8)
    private static let whitespace = Set(" \t\r\n".utf8)
}
