import Foundation
import Compression

// MARK: - 极简 ZIP 读取（只做解析 IPA 需要的部分）
// 读中央目录、按条目解压（stored / deflate）。deflate 用系统 Compression 框架（其 ZLIB 即原始 deflate 流）。

struct ZipEntry {
    let name: String
    let method: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let localOffset: Int
}

struct ZipArchive {
    let data: Data
    let entries: [ZipEntry]

    init?(data: Data) {
        self.data = data
        // 找 End of Central Directory（签名 50 4B 05 06），从尾部向前扫
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { return nil }
        var eocd = -1
        let start = max(0, bytes.count - 65557)
        var i = bytes.count - 22
        while i >= start {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        func u16(_ off: Int) -> Int { Int(bytes[off]) | Int(bytes[off + 1]) << 8 }
        func u32(_ off: Int) -> Int { Int(bytes[off]) | Int(bytes[off + 1]) << 8 | Int(bytes[off + 2]) << 16 | Int(bytes[off + 3]) << 24 }
        let count = u16(eocd + 10)
        var off = u32(eocd + 16)
        var list: [ZipEntry] = []
        for _ in 0..<count {
            guard off + 46 <= bytes.count, bytes[off] == 0x50, bytes[off + 1] == 0x4B, bytes[off + 2] == 0x01, bytes[off + 3] == 0x02 else { break }
            let method = u16(off + 10)
            let csize = u32(off + 20)
            let usize = u32(off + 24)
            let nameLen = u16(off + 28)
            let extraLen = u16(off + 30)
            let commentLen = u16(off + 32)
            let local = u32(off + 42)
            let nameBytes = bytes[(off + 46)..<(off + 46 + nameLen)]
            let name = String(bytes: Array(nameBytes), encoding: .utf8) ?? ""
            list.append(ZipEntry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localOffset: local))
            off += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    func entry(named suffix: String) -> ZipEntry? {
        entries.first { $0.name.hasSuffix(suffix) }
    }

    func extract(_ entry: ZipEntry) -> Data? {
        let bytes = [UInt8](data)
        let off = entry.localOffset
        guard off + 30 <= bytes.count, bytes[off] == 0x50, bytes[off + 1] == 0x4B, bytes[off + 2] == 0x03, bytes[off + 3] == 0x04 else { return nil }
        let nameLen = Int(bytes[off + 26]) | Int(bytes[off + 27]) << 8
        let extraLen = Int(bytes[off + 28]) | Int(bytes[off + 29]) << 8
        let dataStart = off + 30 + nameLen + extraLen
        guard dataStart + entry.compressedSize <= bytes.count else { return nil }
        let raw = Data(bytes[dataStart..<(dataStart + entry.compressedSize)])
        if entry.method == 0 { return raw }
        if entry.method == 8 { return inflate(raw, expectedSize: entry.uncompressedSize) }
        return nil
    }

    private func inflate(_ raw: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        let dstDummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let srcDummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        var stream = compression_stream(dst_ptr: dstDummy, dst_size: 0, src_ptr: UnsafePointer(srcDummy), src_size: 0, state: nil)
        dstDummy.deallocate()
        srcDummy.deallocate()
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        var output = Data(count: expectedSize)
        let result = raw.withUnsafeBytes { srcBuf -> Bool in
            output.withUnsafeMutableBytes { dstBuf -> Bool in
                stream.src_ptr = srcBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.src_size = raw.count
                stream.dst_ptr = dstBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = expectedSize
                let status = compression_stream_process(&stream, 0)
                return status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END
            }
        }
        return result ? output : nil
    }
}

// MARK: - IPA 解析

struct ProvisionInfo {
    var teamName: String = ""
    var teamId: String = ""
    var appIdName: String = ""
    var creation: Date? = nil
    var expiration: Date? = nil

    var daysLeft: Int? {
        guard let expiration else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiration).day
    }
}

struct IPAInfo {
    var displayName: String = ""
    var bundleId: String = ""
    var version: String = ""
    var minOS: String = ""
    var iconData: Data? = nil
    var signed: Bool = false
    var provision: ProvisionInfo? = nil
}

enum IPAParser {
    static func parse(data: Data) -> IPAInfo? {
        guard let zip = ZipArchive(data: data) else { return nil }
        // 定位 Payload/<App>.app/Info.plist
        guard let infoEntry = zip.entries.first(where: { $0.name.hasPrefix("Payload/") && $0.name.hasSuffix(".app/Info.plist") }),
              let infoData = zip.extract(infoEntry),
              let plist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        var info = IPAInfo()
        info.displayName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? "未知应用"
        info.bundleId = plist["CFBundleIdentifier"] as? String ?? ""
        let short = plist["CFBundleShortVersionString"] as? String ?? ""
        let build = plist["CFBundleVersion"] as? String ?? ""
        info.version = short.isEmpty ? build : (build.isEmpty ? short : "\(short) (\(build))")
        info.minOS = plist["MinimumOSVersion"] as? String ?? ""

        let appPrefix = String(infoEntry.name.dropLast("Info.plist".count))

        // 签名状态：_CodeSignature/CodeResources 是否存在
        info.signed = zip.entries.contains { $0.name == appPrefix + "_CodeSignature/CodeResources" }

        // 描述文件
        if let provEntry = zip.entry(named: ".app/embedded.mobileprovision"),
           let provData = zip.extract(provEntry) {
            info.provision = parseProvision(provData)
            info.signed = true
        }

        // 图标：按 Info.plist 声明找根目录 PNG，找不到就找最大的 AppIcon PNG
        var iconNames: [String] = []
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            iconNames = files
        }
        var iconData: Data? = nil
        for base in iconNames {
            for candidate in ["\(base)@3x.png", "\(base)@2x.png", "\(base).png", "\(base)60x60@2x.png"] {
                if let e = zip.entries.first(where: { $0.name == appPrefix + candidate }),
                   let d = zip.extract(e) {
                    iconData = d
                    break
                }
            }
            if iconData != nil { break }
        }
        if iconData == nil {
            let pngs = zip.entries.filter { $0.name.hasPrefix(appPrefix) && $0.name.lowercased().contains("icon") && $0.name.hasSuffix(".png") }
            if let biggest = pngs.max(by: { $0.uncompressedSize < $1.uncompressedSize }) {
                iconData = zip.extract(biggest)
            }
        }
        info.iconData = iconData
        return info
    }

    static func parseProvision(_ data: Data) -> ProvisionInfo? {
        // mobileprovision 是 CMS 签名包裹的 plist，截取其中的 XML plist 部分解析
        guard let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let xmlData = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil) as? [String: Any] else { return nil }
        var info = ProvisionInfo()
        info.teamName = plist["TeamName"] as? String ?? ""
        if let teams = plist["TeamIdentifier"] as? [String] { info.teamId = teams.first ?? "" }
        info.appIdName = plist["AppIDName"] as? String ?? ""
        info.creation = plist["CreationDate"] as? Date
        info.expiration = plist["ExpirationDate"] as? Date
        return info
    }
}
