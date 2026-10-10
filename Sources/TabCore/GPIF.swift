import Foundation

/// Reads and patches the song-info elements at the top of `<Score>` in a
/// score.gpif document (used by both GP6 .gpx and GP7+ .gp files).
///
/// This is deliberately a targeted text edit rather than an XML round-trip, so
/// everything outside the edited elements stays byte-identical.
enum GPIF {
    static let tags: [Field: String] = [
        .title: "Title", .subtitle: "SubTitle", .artist: "Artist", .album: "Album",
        .words: "Words", .music: "Music", .copyright: "Copyright", .tabber: "Tabber",
        .instructions: "Instructions", .notices: "Notices",
    ]

    static func read(_ data: Data) throws -> TabMetadata {
        let xml = String(decoding: data, as: UTF8.self)
        let region = try scoreRegion(in: xml)
        var meta = TabMetadata()
        for (field, tag) in tags {
            if let element = element(tag, in: xml, region: region) {
                meta[field] = decodeContent(String(xml[element.content]))
            }
        }
        return meta
    }

    static func apply(_ changes: [Field: String], to data: Data) throws -> Data {
        var xml = String(decoding: data, as: UTF8.self)
        // Each edit shifts indices, so the region is re-located for every field.
        for (field, value) in changes {
            guard let tag = tags[field] else { continue }
            let region = try scoreRegion(in: xml)
            let replacement = "<\(tag)>\(encodeContent(value))</\(tag)>"
            if let element = element(tag, in: xml, region: region) {
                xml.replaceSubrange(element.whole, with: replacement)
            } else {
                xml.insert(contentsOf: "\n" + replacement, at: region.lowerBound)
            }
        }
        return Data(xml.utf8)
    }

    /// From just after `<Score>` up to the first rich-text header block or `</Score>`.
    private static func scoreRegion(in xml: String) throws -> Range<String.Index> {
        guard let open = xml.range(of: "<Score>") else { throw TabError("score.gpif has no <Score> element") }
        let rest = open.upperBound ..< xml.endIndex
        let end = [xml.range(of: "<FirstPageHeader", range: rest), xml.range(of: "</Score>", range: rest)]
            .compactMap { $0?.lowerBound }.min() ?? xml.endIndex
        return open.upperBound ..< end
    }

    private static func element(_ tag: String, in xml: String, region: Range<String.Index>)
        -> (whole: Range<String.Index>, content: Range<String.Index>)?
    {
        guard let open = xml.range(of: "<\(tag)(\\s*/)?>", options: .regularExpression, range: region) else {
            return nil
        }
        if xml[open].hasSuffix("/>") { return (open, open.upperBound ..< open.upperBound) }
        guard let close = xml.range(of: "</\(tag)>", range: open.upperBound ..< xml.endIndex)
        else { return nil }
        return (open.lowerBound ..< close.upperBound, open.upperBound ..< close.lowerBound)
    }

    static func decodeContent(_ content: String) -> String {
        var result = ""
        var rest = Substring(content)
        while !rest.isEmpty {
            if let cdata = rest.range(of: "<![CDATA[") {
                result += unescape(rest[rest.startIndex ..< cdata.lowerBound])
                guard let end = rest.range(of: "]]>", range: cdata.upperBound ..< rest.endIndex) else {
                    result += rest[cdata.upperBound...]
                    break
                }
                result += rest[cdata.upperBound ..< end.lowerBound]
                rest = rest[end.upperBound...]
            } else {
                result += unescape(rest)
                break
            }
        }
        return result
    }

    static func encodeContent(_ value: String) -> String {
        "<![CDATA[" + value.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
    }

    private static func unescape(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
