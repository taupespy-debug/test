import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
import Vision

/// The barcode types Gym Pass can draw. Scanning picks the right one automatically.
enum BarcodeKind: String, Codable, CaseIterable, Identifiable {
    case code128, code39, qr, pdf417, aztec, ean13, upca, ean8, itf, codabar

    var id: String { rawValue }

    var name: String {
        switch self {
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .qr: return "QR code"
        case .pdf417: return "PDF417"
        case .aztec: return "Aztec"
        case .ean13: return "EAN-13"
        case .upca: return "UPC-A"
        case .ean8: return "EAN-8"
        case .itf: return "ITF (Interleaved 2 of 5)"
        case .codabar: return "Codabar"
        }
    }

    /// QR and Aztec are square; everything else is wide.
    var isSquare: Bool { self == .qr || self == .aztec }

    static func from(metadata type: AVMetadataObject.ObjectType) -> BarcodeKind {
        switch type {
        case .qr, .microQR, .dataMatrix: return .qr
        case .code128: return .code128
        case .code39, .code39Mod43: return .code39
        case .ean13: return .ean13
        case .ean8: return .ean8
        case .itf14, .interleaved2of5: return .itf
        case .pdf417, .microPDF417: return .pdf417
        case .aztec: return .aztec
        case .codabar: return .codabar
        default: return .code128
        }
    }

    static func from(vision s: VNBarcodeSymbology) -> BarcodeKind {
        switch s {
        case .qr, .microQR, .dataMatrix: return .qr
        case .code128: return .code128
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: return .code39
        case .ean13: return .ean13
        case .ean8: return .ean8
        case .itf14, .i2of5, .i2of5Checksum: return .itf
        case .pdf417, .microPDF417: return .pdf417
        case .aztec: return .aztec
        case .codabar: return .codabar
        default: return .code128
        }
    }
}

enum Barcode {
    private static let cache = NSCache<NSString, UIImage>()
    private static let ci = CIContext()

    /// A crisp black-on-white image of the barcode, or nil if the value doesn't fit the type.
    static func image(_ value: String, kind: BarcodeKind) -> UIImage? {
        let key = "\(kind.rawValue)|\(value)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img: UIImage?
        switch kind {
        case .qr, .code128, .pdf417, .aztec: img = coreImage(value, kind: kind)
        default: img = modules(value, kind: kind).map { render($0) }
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    /// Why a value can't be drawn as this type (shown in the editor), or nil if it's fine.
    static func problem(_ value: String, kind: BarcodeKind) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return "Enter the number on your card." }
        let digits = v.allSatisfy { $0.isASCII && $0.isNumber }
        switch kind {
        case .ean13: return digits && (v.count == 12 || v.count == 13) ? nil : "EAN-13 needs 12 or 13 digits."
        case .upca: return digits && (v.count == 11 || v.count == 12) ? nil : "UPC-A needs 11 or 12 digits."
        case .ean8: return digits && (v.count == 7 || v.count == 8) ? nil : "EAN-8 needs 7 or 8 digits."
        case .itf: return digits ? nil : "ITF only takes digits."
        case .code39:
            return v.uppercased().allSatisfy { code39[$0] != nil && $0 != "*" } ? nil
                : "Code 39 takes A–Z, 0–9, space and - . $ / + %"
        case .codabar:
            return codabarBody(v) != nil ? nil : "Codabar takes 0–9 and - $ : / . +"
        case .code128: return v.allSatisfy(\.isASCII) ? nil : "Code 128 can't hold that character."
        default: return image(v, kind: kind) == nil ? "Can't make this barcode." : nil
        }
    }

    // MARK: Core Image (QR, Code 128, PDF417, Aztec)

    private static func coreImage(_ value: String, kind: BarcodeKind) -> UIImage? {
        let output: CIImage?
        switch kind {
        case .qr:
            let f = CIFilter.qrCodeGenerator()
            f.message = Data(value.utf8)
            f.correctionLevel = "M"
            output = f.outputImage
        case .code128:
            guard let data = value.data(using: .ascii) else { return nil }
            let f = CIFilter.code128BarcodeGenerator()
            f.message = data
            f.quietSpace = 10
            f.barcodeHeight = Float(max(40, (value.count * 11 + 55) / 3))
            output = f.outputImage
        case .pdf417:
            let f = CIFilter.pdf417BarcodeGenerator()
            f.message = Data(value.utf8)
            output = f.outputImage
        case .aztec:
            let f = CIFilter.aztecCodeGenerator()
            f.message = Data(value.utf8)
            output = f.outputImage
        default:
            output = nil
        }
        guard let out = output, out.extent.width > 0 else { return nil }
        // scale by a whole number so every bar stays sharp
        let s = max(1, (900 / out.extent.width).rounded(.down))
        let scaled = out.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = ci.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Drawn by hand (Code 39, EAN/UPC, ITF, Codabar). true = black module.

    static func modules(_ value: String, kind: BarcodeKind) -> [Bool]? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard problem(v, kind: kind) == nil else { return nil }
        let d = v.compactMap(\.wholeNumberValue)
        switch kind {
        case .code39: return code39Modules(v.uppercased())
        case .ean13: return ean13Modules(d.count == 12 ? d + [eanCheck(d)] : d)
        case .upca:
            let full = d.count == 11 ? d + [eanCheck(d)] : d
            return ean13Modules([0] + full)
        case .ean8: return ean8Modules(d.count == 7 ? d + [eanCheck(d)] : d)
        case .itf: return itfModules(d.count % 2 == 1 ? [0] + d : d)
        case .codabar: return codabarBody(v).flatMap(codabarModules)
        default: return nil
        }
    }

    private static func bits(_ s: String) -> [Bool] { s.map { $0 == "1" } }

    private static func widths(_ pattern: String, startWithBar: Bool = true) -> [Bool] {
        var out: [Bool] = []
        for (i, e) in pattern.enumerated() {
            let bar = (i % 2 == 0) == startWithBar
            out += Array(repeating: bar, count: e == "w" ? 3 : 1)
        }
        return out
    }

    // Code 39: 9 elements (bar, space, bar...), n = narrow, w = wide
    static let code39: [Character: String] = [
        "0": "nnnwwnwnn", "1": "wnnwnnnnw", "2": "nnwwnnnnw", "3": "wnwwnnnnn", "4": "nnnwwnnnw",
        "5": "wnnwwnnnn", "6": "nnwwwnnnn", "7": "nnnwnnwnw", "8": "wnnwnnwnn", "9": "nnwwnnwnn",
        "A": "wnnnnwnnw", "B": "nnwnnwnnw", "C": "wnwnnwnnn", "D": "nnnnwwnnw", "E": "wnnnwwnnn",
        "F": "nnwnwwnnn", "G": "nnnnnwwnw", "H": "wnnnnwwnn", "I": "nnwnnwwnn", "J": "nnnnwwwnn",
        "K": "wnnnnnnww", "L": "nnwnnnnww", "M": "wnwnnnnwn", "N": "nnnnwnnww", "O": "wnnnwnnwn",
        "P": "nnwnwnnwn", "Q": "nnnnnnwww", "R": "wnnnnnwwn", "S": "nnwnnnwwn", "T": "nnnnwnwwn",
        "U": "wwnnnnnnw", "V": "nwwnnnnnw", "W": "wwwnnnnnn", "X": "nwnnwnnnw", "Y": "wwnnwnnnn",
        "Z": "nwwnwnnnn", "-": "nwnnnnwnw", ".": "wwnnnnwnn", " ": "nwwnnnwnn", "*": "nwnnwnwnn",
        "$": "nwnwnwnnn", "/": "nwnwnnnwn", "+": "nwnnnwnwn", "%": "nnnwnwnwn",
    ]

    private static func code39Modules(_ v: String) -> [Bool]? {
        var out: [Bool] = []
        for (i, c) in ("*" + v + "*").enumerated() {
            guard let p = code39[c] else { return nil }
            if i > 0 { out.append(false) }  // narrow gap between characters
            out += widths(p)
        }
        return out
    }

    // EAN / UPC: L codes; R codes are L inverted, G codes are R reversed
    static let eanL = ["0001101", "0011001", "0010011", "0111101", "0100011",
                       "0110001", "0101111", "0111011", "0110111", "0001011"]
    static let eanParity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG",
                            "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
    private static func eanR(_ d: Int) -> String { String(eanL[d].map { $0 == "0" ? "1" : "0" }) }
    private static func eanG(_ d: Int) -> String { String(eanR(d).reversed()) }

    /// Check digit for EAN-13 / EAN-8 / UPC-A (digits without the check digit).
    static func eanCheck(_ digits: [Int]) -> Int {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() { sum += d * (i % 2 == 0 ? 3 : 1) }
        return (10 - sum % 10) % 10
    }

    private static func ean13Modules(_ d: [Int]) -> [Bool]? {
        guard d.count == 13 else { return nil }
        let parity = Array(eanParity[d[0]])
        var s = "101"
        for i in 1...6 { s += parity[i - 1] == "L" ? eanL[d[i]] : eanG(d[i]) }
        s += "01010"
        for i in 7...12 { s += eanR(d[i]) }
        s += "101"
        return bits(s)
    }

    private static func ean8Modules(_ d: [Int]) -> [Bool]? {
        guard d.count == 8 else { return nil }
        var s = "101"
        for i in 0...3 { s += eanL[d[i]] }
        s += "01010"
        for i in 4...7 { s += eanR(d[i]) }
        s += "101"
        return bits(s)
    }

    // ITF: digits in pairs, first digit in the bars, second in the spaces
    static let itf = ["nnwwn", "wnnnw", "nwnnw", "wwnnn", "nnwnw",
                      "wnwnn", "nwwnn", "nnnww", "wnnwn", "nwnwn"]

    private static func itfModules(_ d: [Int]) -> [Bool]? {
        guard !d.isEmpty, d.count % 2 == 0 else { return nil }
        var out = bits("1010")
        for i in stride(from: 0, to: d.count, by: 2) {
            let a = Array(itf[d[i]]), b = Array(itf[d[i + 1]])
            for k in 0..<5 {
                out += Array(repeating: true, count: a[k] == "w" ? 3 : 1)
                out += Array(repeating: false, count: b[k] == "w" ? 3 : 1)
            }
        }
        out += bits("11101")
        return out
    }

    // Codabar: module strings (1 = bar), wide elements are 2 modules
    static let codabar: [Character: String] = [
        "0": "101010011", "1": "101011001", "2": "101001011", "3": "110010101", "4": "101101001",
        "5": "110101001", "6": "100101011", "7": "100101101", "8": "100110101", "9": "110100101",
        "-": "101001101", "$": "101100101", ":": "1101011011", "/": "1101101011", ".": "1101101101",
        "+": "1011011011", "A": "1011001001", "B": "1001001011", "C": "1010010011", "D": "1010011001",
    ]

    /// The full Codabar text with start/stop letters, or nil if it has characters Codabar can't hold.
    private static func codabarBody(_ v: String) -> String? {
        var s = v.uppercased()
        let ends: Set<Character> = ["A", "B", "C", "D"]
        if s.count >= 2, let f = s.first, let l = s.last, ends.contains(f), ends.contains(l) {
            // already has start/stop
        } else {
            s = "A" + s + "B"
        }
        let middle = s.dropFirst().dropLast()
        guard !middle.isEmpty, middle.allSatisfy({ codabar[$0] != nil && !ends.contains($0) }) else { return nil }
        return s
    }

    private static func codabarModules(_ s: String) -> [Bool]? {
        var out: [Bool] = []
        for (i, c) in s.enumerated() {
            guard let p = codabar[c] else { return nil }
            if i > 0 { out.append(false) }
            out += bits(p)
        }
        return out
    }

    /// Draws modules at 3 px each, with a quiet zone of 10 modules on both sides.
    static func render(_ m: [Bool]) -> UIImage {
        let scale = 3, quiet = 10
        let w = (m.count + quiet * 2) * scale
        let h = max(120, w / 3)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            UIColor.black.setFill()
            for (i, on) in m.enumerated() where on {
                ctx.fill(CGRect(x: (i + quiet) * scale, y: 0, width: scale, height: h))
            }
        }
    }
}

/// Finds a barcode in a photo or screenshot.
enum PhotoBarcode {
    static func detect(in data: Data) -> (String, BarcodeKind)? {
        let req = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(data: data, options: [:])
        try? handler.perform([req])
        guard let hit = req.results?.first(where: { !($0.payloadStringValue ?? "").isEmpty }),
              let s = hit.payloadStringValue else { return nil }
        return (s, BarcodeKind.from(vision: hit.symbology))
    }
}
