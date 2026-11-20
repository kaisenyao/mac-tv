import Compression
import Foundation
import Testing
@testable import MacTV

/// 直播间弹幕的协议：包头、一帧里好几个包、压缩过的帧、DANMU_MSG 读成弹幕。内容都是手写的
@Suite(.timeLimit(.minutes(1)))
struct BiliLiveDanmakuTests {
    private typealias Wire = BiliLiveDanmakuProtocol

    /// 一条手写的 DANMU_MSG：info[0] 里第 2 个是怎么走，第 4 个是颜色；info[1] 是内容
    private func message(_ text: String, mode: Int = 1, color: Int = 0xFFFFFF, command: String = "DANMU_MSG") -> Data {
        let json: [String: Any] = ["cmd": command, "info": [[0, mode, 25, color, 1_700_000_000, 0, 0, "", 0, 0, 0, ""], text, [1, "某人"]]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test
    func headerRoundTrips() throws {
        let body = Data("{\"code\":0}".utf8)
        let packet = Wire.encode(operation: Wire.enterReply, body: body)
        // 整包长度 26、头长 16、版本 1、操作码 8、序号 1（都是大端）
        #expect([UInt8](packet.prefix(16)) == [0, 0, 0, 26, 0, 16, 0, 1, 0, 0, 0, 8, 0, 0, 0, 1])
        #expect(Wire.packets(in: packet) == [Wire.Packet(version: 1, operation: 8, body: body)])
        // 进房间的包：操作码 7，包身是 JSON（凭证、房间号、要 brotli 压缩的版本 3）
        let enter = Wire.packets(in: Wire.enter(room: 42, uid: 0, buvid: "B", key: "K")).first
        let fields = try #require(enter.flatMap { try JSONSerialization.jsonObject(with: $0.body) as? [String: Any] })
        #expect(enter?.operation == 7 && fields["roomid"] as? Int == 42 && fields["protover"] as? Int == 3 && fields["key"] as? String == "K")
    }

    /// 一帧里连着好几个包；后面不完整的那一截不要
    @Test
    func framesSplitIntoPackets() {
        let body = message("一")
        let first = Wire.encode(operation: Wire.message, body: body, version: 0)
        let second = Wire.encode(operation: 3, body: Data([0, 0, 0, 9]))
        let packets = Wire.packets(in: first + second + Data([0, 0, 0, 99, 0, 16]))
        #expect(packets.map(\.operation) == [5, 3])
        #expect(packets.first?.body == body && packets.last?.body == Data([0, 0, 0, 9]))
    }

    /// 压缩过的帧：版本 2（zlib）、版本 3（brotli）里面又是一串包，解开后接着拆
    @Test
    func compressedFramesUnpack() throws {
        let inner = Wire.encode(operation: Wire.message, body: message("甲"), version: 0)
            + Wire.encode(operation: Wire.message, body: message("乙", mode: 5), version: 0)
        let deflated = try #require(encode(inner, COMPRESSION_ZLIB))
        let zlibFrame = Wire.encode(operation: Wire.message, body: Data([0x78, 0x9C]) + deflated, version: 2)
        #expect(Wire.packets(in: zlibFrame).compactMap { Wire.danmaku(from: $0.body)?.text } == ["甲", "乙"])
        // brotli：系统能压的时候才测（解压是一直都能）
        if let brotli = encode(inner, COMPRESSION_BROTLI) {
            let frame = Wire.encode(operation: Wire.message, body: brotli, version: 3)
            #expect(Wire.packets(in: frame).map(\.operation) == [5, 5])
            #expect(Wire.packets(in: frame).compactMap { Wire.danmaku(from: $0.body)?.kind } == [.scroll, .top])
        }
        // 坏的压缩数据：什么都不出，不崩
        #expect(Wire.packets(in: Wire.encode(operation: Wire.message, body: Data([1, 2, 3, 4]), version: 3)).isEmpty)
    }

    /// DANMU_MSG：内容、颜色、怎么走；别的消息、高级弹幕、空的不要
    @Test
    func danmuMessagesBecomeDanmaku() {
        let red = Wire.danmaku(from: message("红色的一条\n", color: 0xFF0000, command: "DANMU_MSG:4:0:2:2:2:0"), at: 12)
        #expect(red == BiliDanmaku(time: 12, kind: .scroll, size: 1, color: 0xFF0000, text: "红色的一条"))
        #expect(Wire.danmaku(from: message("顶上", mode: 5))?.kind == .top)
        #expect(Wire.danmaku(from: message("底下", mode: 4))?.kind == .bottom)
        #expect(Wire.danmaku(from: message("高级", mode: 7)) == nil)
        #expect(Wire.danmaku(from: message("  ")) == nil)
        #expect(Wire.danmaku(from: message("礼物", command: "SEND_GIFT")) == nil)
        #expect(Wire.danmaku(from: Data("not json".utf8)) == nil)
    }

    /// 来一条排一条（直播）和一次排完（视频）排出来的一样
    @Test
    func lanesPlaceOneByOneLikeABatch() {
        let layout = BiliDanmakuLayout(style: BiliDanmakuStyle())
        let items = (0..<40).map { BiliDanmaku(time: Double($0) * 0.2, kind: $0 % 7 == 0 ? .top : .scroll, size: 1, color: 0xFFFFFF, text: "第\($0)条弹幕") }
        var lanes = BiliDanmakuLayout.Lanes(layout)
        #expect(items.compactMap { lanes.place($0) } == layout.place(items))
    }

    private func encode(_ data: Data, _ algorithm: compression_algorithm) -> Data? {
        var output = [UInt8](repeating: 0, count: data.count + 1024)
        let count = data.withUnsafeBytes { source in
            compression_encode_buffer(&output, output.count, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
        }
        return count > 0 ? Data(output.prefix(count)) : nil
    }
}
