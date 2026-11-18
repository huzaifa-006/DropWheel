import Foundation
import CoreGraphics

/// Minimal ZIP writer (stored entries) – enough to build .docx packages without dependencies.
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var entries = 0

    mutating func add(_ name: String, _ content: Data) {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(content)
        let offset = UInt32(data.count)
        // Local file header
        data.append(u32(0x0403_4b50)); data.append(u16(20)); data.append(u16(0x0800)); data.append(u16(0))
        data.append(u16(0)); data.append(u16(0x21))  // time, date (1980-01-01)
        data.append(u32(crc)); data.append(u32(UInt32(content.count))); data.append(u32(UInt32(content.count)))
        data.append(u16(UInt16(nameBytes.count))); data.append(u16(0))
        data.append(nameBytes); data.append(content)
        // Central directory record
        central.append(u32(0x0201_4b50)); central.append(u16(20)); central.append(u16(20)); central.append(u16(0x0800))
        central.append(u16(0)); central.append(u16(0)); central.append(u16(0x21))
        central.append(u32(crc)); central.append(u32(UInt32(content.count))); central.append(u32(UInt32(content.count)))
        central.append(u16(UInt16(nameBytes.count))); central.append(u16(0)); central.append(u16(0))
        central.append(u16(0)); central.append(u16(0)); central.append(u32(0)); central.append(u32(offset))
        central.append(nameBytes)
        entries += 1
    }

    func finish() -> Data {
        var out = data
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(u32(0x0605_4b50)); out.append(u16(0)); out.append(u16(0))
        out.append(u16(UInt16(entries))); out.append(u16(UInt16(entries)))
        out.append(u32(UInt32(central.count))); out.append(u32(cdOffset)); out.append(u16(0))
        return out
    }

    private func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private func u32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
}

/// Builds Word documents from paragraphs, page breaks and images.
public struct DocxBuilder {
    public enum Block {
        case paragraph(String)
        case heading(String)
        case pageBreak
        case image(png: Data, pixelWidth: Int, pixelHeight: Int)
    }

    public var blocks: [Block] = []
    public init() {}

    public mutating func add(_ block: Block) { blocks.append(block) }

    public func data() -> Data {
        var body = ""
        var rels = ""
        var media: [(String, Data)] = []
        for block in blocks {
            switch block {
            case .paragraph(let text):
                body += "<w:p>\(runs(text))</w:p>"
            case .heading(let text):
                body += "<w:p><w:pPr><w:pStyle w:val=\"Heading1\"/></w:pPr>\(runs(text))</w:p>"
            case .pageBreak:
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            case .image(let png, let pw, let ph):
                let n = media.count + 1
                let rid = "rIdImg\(n)"
                media.append(("image\(n).png", png))
                rels += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\(n).png\"/>"
                // Fit inside a 6.5" wide text column (EMU: 914400 per inch).
                let maxW = 6.5 * 914_400.0, maxH = 9.0 * 914_400.0
                let natW = Double(pw) / 96.0 * 914_400.0, natH = Double(ph) / 96.0 * 914_400.0
                let s = min(1, maxW / natW, maxH / natH)
                let cx = Int(natW * s), cy = Int(natH * s)
                body += """
                <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
                <wp:docPr id="\(n)" name="Picture \(n)"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
                <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
                <pic:nvPicPr><pic:cNvPr id="\(n)" name="image\(n).png"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            }
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
        <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="120"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style></w:styles>
        """
        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\(rels)</Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(rootRels.utf8))
        zip.add("word/document.xml", Data(document.utf8))
        zip.add("word/styles.xml", Data(styles.utf8))
        zip.add("word/_rels/document.xml.rels", Data(docRels.utf8))
        for (name, bytes) in media { zip.add("word/media/\(name)", bytes) }
        return zip.finish()
    }

    private func runs(_ text: String) -> String {
        // Preserve tabs and line breaks inside a paragraph.
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { idx, line in
            let parts = line.components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\(escape($0))</w:t>" }
            return (idx > 0 ? "<w:r><w:br/></w:r>" : "") + "<w:r>" + parts.joined(separator: "<w:tab/>") + "</w:r>"
        }.joined()
    }

    private func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 forbids most control characters.
                if scalar.value < 0x20 && scalar != "\t" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
