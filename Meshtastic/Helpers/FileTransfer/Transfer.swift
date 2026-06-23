import Foundation

/// Chunked transfer protocol for sending files and codec2 voice over Meshtastic.
///
/// A faithful port of the bridge's `transfer.py`, so packets produced here are
/// reassembled by ha-bridge nodes and vice-versa. Meshtastic data packets carry
/// at most 233 bytes, so anything larger is split into chunks and reassembled.
///
/// Wire format (big-endian), one per Meshtastic packet:
///
///     Common header (4 bytes)
///         0      magic = 0xC2
///         1      (version << 4) | type     version=1, type: 0=manifest 1=data
///         2..3   transfer id (uint16)
///     MANIFEST (type 0) body
///         kind(1) total_size(4) total_chunks(2) chunk_size(2) crc32(4)
///         name_len(1) name(...) ctype_len(1) content_type(...)
///     DATA (type 1) body
///         chunk_idx(2) total_chunks(2) payload(...)
enum Transfer {
    static let magic: UInt8 = 0xC2
    static let version: UInt8 = 1
    static let typeManifest: UInt8 = 0
    static let typeData: UInt8 = 1

    static let kindFile = 0
    static let kindVoice = 1
    static func kindName(_ k: Int) -> String { k == kindVoice ? "voice" : "file" }

    /// Meshtastic Data.payload hard limit is 233 bytes; leave header + PKI room.
    static let meshPayloadLimit = 233
    static let dataHeaderLen = 8
    static let defaultChunkSize = 200
    /// ha-bridge's file portnum (private app pool); files are chunked here.
    static let filePortnum = 305

    private static func verType(_ t: UInt8) -> UInt8 { ((version & 0x0F) << 4) | (t & 0x0F) }

    // MARK: Packing

    static func packManifest(xferID: Int, kind: Int, totalSize: Int, totalChunks: Int,
                             chunkSize: Int, payloadCRC32: UInt32, name: String,
                             contentType: String) -> Data {
        var d = Data()
        d.appendU8(magic)
        d.appendU8(verType(typeManifest))
        d.appendU16BE(UInt16(xferID & 0xFFFF))
        d.appendU8(UInt8(kind & 0xFF))
        d.appendU32BE(UInt32(truncatingIfNeeded: totalSize))
        d.appendU16BE(UInt16(totalChunks & 0xFFFF))
        d.appendU16BE(UInt16(chunkSize & 0xFFFF))
        d.appendU32BE(payloadCRC32)
        let nameB = Array(name.utf8.prefix(255))
        d.appendU8(UInt8(nameB.count)); d.append(contentsOf: nameB)
        let ctypeB = Array(contentType.utf8.prefix(255))
        d.appendU8(UInt8(ctypeB.count)); d.append(contentsOf: ctypeB)
        return d
    }

    static func packData(xferID: Int, chunkIdx: Int, totalChunks: Int, payload: Data) -> Data {
        var d = Data()
        d.appendU8(magic)
        d.appendU8(verType(typeData))
        d.appendU16BE(UInt16(xferID & 0xFFFF))
        d.appendU16BE(UInt16(chunkIdx & 0xFFFF))
        d.appendU16BE(UInt16(totalChunks & 0xFFFF))
        d.append(payload)
        return d
    }

    // MARK: Parsing

    enum Parsed {
        case manifest(xferID: Int, kind: Int, totalSize: Int, totalChunks: Int,
                      chunkSize: Int, crc32: UInt32, name: String, contentType: String)
        case data(xferID: Int, chunkIdx: Int, totalChunks: Int, payload: Data)
    }

    /// Parse one of our packets. Returns nil if it isn't ours / is malformed.
    static func parse(_ data: Data) -> Parsed? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == magic, (b[1] >> 4) == version else { return nil }
        let ptype = b[1] & 0x0F
        let xferID = Int(b[2]) << 8 | Int(b[3])
        var off = 4
        if ptype == typeManifest {
            guard b.count >= off + 13 else { return nil }
            let kind = Int(b[off]); off += 1
            let totalSize = u32(b, off); off += 4
            let totalChunks = u16(b, off); off += 2
            let chunkSize = u16(b, off); off += 2
            let crc = UInt32(u32(b, off)); off += 4
            guard b.count >= off + 1 else { return nil }
            let nameLen = Int(b[off]); off += 1
            guard b.count >= off + nameLen else { return nil }
            let name = String(decoding: b[off..<off + nameLen], as: UTF8.self); off += nameLen
            guard b.count >= off + 1 else { return nil }
            let ctypeLen = Int(b[off]); off += 1
            guard b.count >= off + ctypeLen else { return nil }
            let ctype = String(decoding: b[off..<off + ctypeLen], as: UTF8.self)
            return .manifest(xferID: xferID, kind: kind, totalSize: totalSize,
                             totalChunks: totalChunks, chunkSize: chunkSize, crc32: crc,
                             name: name, contentType: ctype)
        }
        if ptype == typeData {
            guard b.count >= off + 4 else { return nil }
            let chunkIdx = u16(b, off); off += 2
            let totalChunks = u16(b, off); off += 2
            return .data(xferID: xferID, chunkIdx: chunkIdx, totalChunks: totalChunks,
                         payload: Data(b[off...]))
        }
        return nil
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }

    // MARK: Send plan

    struct SendPlan {
        let xferID: Int
        let manifest: Data
        let dataPackets: [Data]
        let totalChunks: Int
        let totalSize: Int
        var packetSizes: [Int] { [manifest.count] + dataPackets.map { $0.count } }
    }

    static func splitPayload(_ blob: Data, chunkSize: Int) -> [Data] {
        precondition(chunkSize > 0, "chunk_size must be positive")
        if blob.isEmpty { return [Data()] }
        var out: [Data] = []
        var i = blob.startIndex
        while i < blob.endIndex {
            let end = blob.index(i, offsetBy: chunkSize, limitedBy: blob.endIndex) ?? blob.endIndex
            out.append(Data(blob[i..<end]))
            i = end
        }
        return out
    }

    static func buildSendPlan(xferID: Int, blob: Data, kind: Int, name: String,
                             contentType: String, chunkSize: Int = defaultChunkSize) -> SendPlan {
        let chunks = splitPayload(blob, chunkSize: chunkSize)
        let totalChunks = chunks.count
        let manifest = packManifest(xferID: xferID, kind: kind, totalSize: blob.count,
                                    totalChunks: totalChunks, chunkSize: chunkSize,
                                    payloadCRC32: CRC32.checksum(blob), name: name,
                                    contentType: contentType)
        let packets = chunks.enumerated().map { idx, chunk in
            packData(xferID: xferID, chunkIdx: idx, totalChunks: totalChunks, payload: chunk)
        }
        return SendPlan(xferID: xferID, manifest: manifest, dataPackets: packets,
                        totalChunks: totalChunks, totalSize: blob.count)
    }
}

// MARK: - Inbound reassembly

/// Collects chunks for one transfer and reassembles them in order; tolerant of
/// out-of-order and missing chunks. Mirrors `transfer.InboundTransfer`.
final class InboundTransfer {
    let xferID: Int
    let fromID: String?
    let portnum: Int
    var kind: Int?
    var totalSize: Int?
    var totalChunks: Int?
    var chunkSize: Int?
    var crc32: UInt32?
    var name: String?
    var contentType: String?
    private(set) var chunks: [Int: Data] = [:]
    let createdAt = Date()
    private(set) var updatedAt = Date()
    private(set) var completed = false
    private(set) var crcOK: Bool?

    init(xferID: Int, fromID: String?, portnum: Int) {
        self.xferID = xferID; self.fromID = fromID; self.portnum = portnum
    }

    func addManifest(kind: Int, totalSize: Int, totalChunks: Int, chunkSize: Int,
                     crc32: UInt32, name: String, contentType: String) {
        self.kind = kind; self.totalSize = totalSize; self.totalChunks = totalChunks
        self.chunkSize = chunkSize; self.crc32 = crc32; self.name = name
        self.contentType = contentType; updatedAt = Date()
    }

    func addData(idx: Int, totalChunks: Int, payload: Data) {
        if self.totalChunks == nil { self.totalChunks = totalChunks }
        chunks[idx] = payload
        updatedAt = Date()
    }

    var isComplete: Bool {
        guard let tc = totalChunks else { return false }
        if chunks.count < tc { return false }
        return (0..<tc).allSatisfy { chunks[$0] != nil }
    }

    func missing() -> [Int] {
        guard let tc = totalChunks else { return [] }
        return (0..<tc).filter { chunks[$0] == nil }
    }

    var progress: Double {
        guard let tc = totalChunks, tc > 0 else { return 0 }
        return min(1.0, Double(chunks.count) / Double(tc))
    }

    func assemble() throws -> Data {
        guard let tc = totalChunks, isComplete else {
            throw TransferError.incomplete
        }
        var blob = Data()
        for i in 0..<tc { blob.append(chunks[i]!) }
        if let expected = crc32 { crcOK = CRC32.checksum(blob) == expected }
        completed = true
        return blob
    }

    enum TransferError: Error { case incomplete }
}

// MARK: - Big-endian Data helpers

extension Data {
    mutating func appendU8(_ v: UInt8) { append(v) }
    mutating func appendU16BE(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendU32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
}
