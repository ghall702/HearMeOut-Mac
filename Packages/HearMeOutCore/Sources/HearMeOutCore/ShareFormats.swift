import Foundation

/// Sharing formats (handbook §7). The Gmail card mirrors the web app's and the Chrome extension's.
public enum ShareFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case link, gmail, embed, message

    public var id: String { rawValue }

    public var action: String {
        switch self {
        case .link: return "Copy Link"
        case .gmail: return "Copy for Gmail"
        case .embed: return "Copy HTML Embed"
        case .message: return "Copy Message"
        }
    }

    public var confirmation: String {
        switch self {
        case .link: return "Link copied"
        case .gmail: return "Gmail card copied — paste it into your email"
        case .embed: return "Embed code copied"
        case .message: return "Message copied"
        }
    }

    public var symbol: String {
        switch self {
        case .link: return "link"
        case .gmail: return "envelope.fill"
        case .embed: return "chevron.left.forwardslash.chevron.right"
        case .message: return "text.bubble.fill"
        }
    }
}

public struct ClipboardPayload: Equatable, Sendable {
    public var plainText: String
    public var html: String?
}

public enum ShareText {
    public static let messagePrefix = "Hey, I've recorded you a voice memo. Click here to listen: "

    /// Plain text never includes the title.
    public static func message(_ shareUrl: String) -> String { messagePrefix + shareUrl }

    public static func shareToken(from shareUrl: String) -> String? {
        guard let u = URL(string: shareUrl) else { return nil }
        let parts = u.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "s" else { return nil }
        let token = String(parts[1])
        guard token.count >= 16, token.count <= 64, token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return token
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Email-safe card: a linked 1200×630 card image shown at 480 px, with a fallback text link.
    public static func gmailCardHTML(_ shareUrl: String) -> String {
        let token = shareToken(from: shareUrl) ?? ""
        let origin: String = {
            guard let u = URL(string: shareUrl), let scheme = u.scheme, let host = u.host else { return "https://hearmeout.george-hall.uk" }
            return "\(scheme)://\(host)"
        }()
        let url = escape(shareUrl)
        let img = escape("\(origin)/api/public/card/\(token)")
        return """
        <p style="font-family:Arial,sans-serif;font-size:15px;color:#1c1c1e;margin:0 0 12px">Hey, I've recorded you a voice memo. Click below to listen.</p>
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;max-width:480px;width:100%"><tr><td>
        <a href="\(url)" target="_blank" style="text-decoration:none;display:block"><img src="\(img)" width="480" alt="▶ Play voice memo" style="display:block;width:100%;max-width:480px;height:auto;border:0;border-radius:16px"></a>
        </td></tr><tr><td style="padding:10px 4px 0;font-family:Arial,sans-serif;font-size:14px">
        <a href="\(url)" target="_blank" style="color:#5f7d66;font-weight:bold;text-decoration:none">▶ Listen to voice memo</a>
        </td></tr></table>
        """
    }

    /// What goes on the clipboard. Rich formats always carry a plain-text fallback.
    public static func payload(_ format: ShareFormat, links: ShareLinks) -> ClipboardPayload {
        switch format {
        case .link: return ClipboardPayload(plainText: links.shareUrl, html: nil)
        case .message: return ClipboardPayload(plainText: message(links.shareUrl), html: nil)
        case .embed: return ClipboardPayload(plainText: links.embedCode, html: nil)
        case .gmail: return ClipboardPayload(plainText: message(links.shareUrl), html: gmailCardHTML(links.shareUrl))
        }
    }
}
