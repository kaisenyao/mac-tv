import AVFoundation
import Foundation
import Testing
@testable import MacTV

/// 网易云音乐里不用联网、不用播放器就能测的那几块：平衡音量、听歌记录、记住进度
@Suite
struct NeteaseTests {
    // MARK: 平衡音量

    @Test
    func loudnessIgnoresMissingOrZeroGain() {
        // 网页版接口的增益一律是 0：当成没给
        #expect(NeteaseAPI.loudness(gain: nil, peak: 1) == nil)
        #expect(NeteaseAPI.loudness(gain: 0, peak: 1) == nil)
        #expect(NeteaseAPI.loudness(gain: .nan, peak: 1) == nil)
    }

    @Test
    func loudnessKeepsCutsAndCapsBoostsAtPeak() {
        // 往下压的照给
        #expect(NeteaseAPI.loudness(gain: -8.7454, peak: 1) == -8.7454)
        // 往上提的不超过峰值留出的空间：峰值 0.5 最多提 6.02 分贝
        #expect(NeteaseAPI.loudness(gain: 5, peak: 0.5) == 5)
        let capped = NeteaseAPI.loudness(gain: 10, peak: 0.5) ?? 0
        #expect(abs(capped - 6.0206) < 0.001)
        // 峰值超过满幅（实测有 1.0374 的）：要压的照压
        #expect(NeteaseAPI.loudness(gain: -6.3, peak: 1.0374) == -6.3)
        // 没给峰值：只看增益
        #expect(NeteaseAPI.loudness(gain: -3, peak: nil) == -3)
        #expect(NeteaseAPI.loudness(gain: -3, peak: 0) == -3)
    }

    @Test @MainActor
    func volumeOnlyTurnsDown() {
        #expect(abs(NeteaseStore.volume(forGain: -6.0206) - 0.5) < 0.001)
        #expect(abs(NeteaseStore.volume(forGain: -20) - 0.1) < 0.0001)
        // 要往上提的歌：播放器音量不能超过 1
        #expect(NeteaseStore.volume(forGain: 5) == 1)
        #expect(NeteaseStore.volume(forGain: 0) == 1)
        // 不知道增益：按一首普通的歌（-7 分贝）
        #expect(abs(NeteaseStore.volume(forGain: nil) - 0.4467) < 0.001)
        for gain in stride(from: -15.0, through: 15, by: 0.5) {
            let volume = NeteaseStore.volume(forGain: gain)
            #expect(volume > 0 && volume <= 1)
        }
    }

    // MARK: 听歌记录

    @Test @MainActor
    func reportThresholdIsThirtySecondsOrHalfASong() {
        #expect(NeteaseStore.reportThreshold(duration: 240) == 30)
        #expect(NeteaseStore.reportThreshold(duration: 60) == 30)
        #expect(NeteaseStore.reportThreshold(duration: 40) == 20)
        #expect(NeteaseStore.reportThreshold(duration: 1) == 1)
        #expect(NeteaseStore.reportThreshold(duration: 0) == 1)   // 不知道时长：听过就算
    }

    @Test
    func playLogsMatchTheWebPlayer() throws {
        let logs = NeteaseAPI.playLogs(song: 2070151218, seconds: 185, finished: true, playlist: 3136952023)
        #expect(logs.count == 2)
        #expect(logs[0]["action"] as? String == "startplay")
        #expect(logs[1]["action"] as? String == "play")
        let start = try #require(logs[0]["json"] as? [String: Any])
        #expect(start["id"] as? Int == 2070151218)
        #expect(start["type"] as? String == "song")
        let play = try #require(logs[1]["json"] as? [String: Any])
        #expect(play["id"] as? Int == 2070151218)
        #expect(play["time"] as? Int == 185)
        #expect(play["end"] as? String == "playend")
        #expect(play["sourceId"] as? String == "3136952023")
        #expect(play["content"] as? String == "id=3136952023")
        #expect(JSONSerialization.isValidJSONObject(logs))

        // 中途切走、不是从歌单放的
        let skipped = NeteaseAPI.playLogs(song: 1, seconds: 40, finished: false, playlist: 0)
        let json = try #require(skipped[1]["json"] as? [String: Any])
        #expect(json["end"] as? String == "interrupt")
        #expect(json["sourceId"] as? String == "")
        #expect(json["content"] as? String == "")
    }

    // MARK: 记住播放进度

    @Test @MainActor
    func resumePositionStartsOverNearTheEnd() {
        #expect(NeteaseStore.resumePosition(saved: 100, duration: 240) == 100)
        #expect(NeteaseStore.resumePosition(saved: 238, duration: 240) == 0)   // 差不多放完了：从头
        #expect(NeteaseStore.resumePosition(saved: 0, duration: 240) == 0)
        #expect(NeteaseStore.resumePosition(saved: -5, duration: 240) == 0)
        #expect(NeteaseStore.resumePosition(saved: .nan, duration: 240) == 0)
        #expect(NeteaseStore.resumePosition(saved: 100, duration: 0) == 100)   // 不知道时长：照记下的
    }

    @Test
    func songsSurviveSavingAndLoading() throws {
        let song = NeteaseSong(id: 2070151218, name: "Be More", artist: "A · B", cover: URL(string: "https://p1.music.126.net/x.jpg"),
                               duration: 215, artists: [NeteaseArtist(id: 1, name: "A"), NeteaseArtist(id: 2, name: "B")],
                               album: 99, albumName: "专辑")
        let data = try JSONEncoder().encode([song, NeteaseSong(id: 5, name: "无封面")])
        let back = try JSONDecoder().decode([NeteaseSong].self, from: data)
        #expect(back.count == 2)
        #expect(back[0].id == song.id && back[0].name == song.name && back[0].artist == song.artist)
        #expect(back[0].cover == song.cover && back[0].duration == 215 && back[0].album == 99 && back[0].albumName == "专辑")
        #expect(back[0].artists.map(\.name) == ["A", "B"])
        #expect(back[1].cover == nil && back[1].artists.isEmpty)
    }
}

extension NeteaseTests {
    /// 记住进度时要把整个播放列表存下来：三千首的歌单也要快、文件也不大
    @Test @MainActor
    func bigQueueSavesQuicklyAndSmall() throws {
        let songs = (0..<3000).map { i in
            NeteaseSong(id: 1_000_000 + i, name: "一首歌的名字 \(i)", artist: "歌手甲 / 歌手乙",
                        cover: URL(string: "https://p2.music.126.net/abcdefghijklmnop/\(i).jpg"), duration: 240,
                        artists: [NeteaseArtist(id: i, name: "歌手甲"), NeteaseArtist(id: i + 1, name: "歌手乙")], album: i, albumName: "专辑名")
        }
        let started = Date()
        let data = try JSONEncoder().encode(NeteaseStore.SavedQueue(songs: songs, index: 1500, source: 42))
        let back = try JSONDecoder().decode(NeteaseStore.SavedQueue.self, from: data)
        let took = Date().timeIntervalSince(started)
        #expect(back.songs.count == 3000 && back.index == 1500 && back.source == 42)
        #expect(data.count < 1_200_000)
        #expect(took < 0.5)
        print("三千首：\(data.count / 1024) KB，存取共 \(Int(took * 1000)) 毫秒")
    }
}

extension NeteaseTests {
    /// 逐字歌词：字在开始唱的那一刻已经（几乎）全亮，不落后半个字；开始前 0.1 秒还没亮；
    /// 很短的字也在下一个字开始前亮满，不会一路拖下去
    @Test @MainActor
    func karaokeWordIsLitWhenItIsSung() {
        let start = 10.0
        #expect(NeteaseKaraokeLine.brightness(at: start - 0.11, start: start, duration: 0.4) == 0)
        #expect(NeteaseKaraokeLine.brightness(at: start, start: start, duration: 0.4) > 0.9)
        #expect(NeteaseKaraokeLine.brightness(at: start + 0.03, start: start, duration: 0.4) == 1)
        // 很短的字（0.08 秒）：在它自己的时长里亮满
        #expect(NeteaseKaraokeLine.brightness(at: start + 0.08 - NeteaseKaraokeLine.lead, start: start, duration: 0.08) == 1)
        // 一直在变亮、不会忽明忽暗
        var last = 0.0
        for step in 0...40 {
            let level = NeteaseKaraokeLine.brightness(at: start - 0.2 + Double(step) * 0.01, start: start, duration: 0.3)
            #expect(level >= last)
            last = level
        }
    }
}

extension NeteaseTests {
    /// 拖进度的档位：每一段至少 5 秒，长的东西是总长的四十分之一；跨过一段才响一声
    @Test
    func scrubDetentsAreEvenSteps() {
        #expect(ScrubDetent.size(duration: 120) == 5)        // 两分钟的歌：5 秒一档
        #expect(ScrubDetent.size(duration: 3600) == 90)      // 一小时的视频：90 秒一档
        #expect(!ScrubDetent.crossed(from: 1, to: 4.9, duration: 120))
        #expect(ScrubDetent.crossed(from: 4.9, to: 5.1, duration: 120))
        #expect(ScrubDetent.crossed(from: 10.2, to: 9.8, duration: 120))   // 往回拖也算
        #expect(!ScrubDetent.crossed(from: 100, to: 170, duration: 3600))
    }

    /// 四种声音都能做出来，"咔"比"嗒"长一点、响一点
    @Test @MainActor
    func everyCueHasASound() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        var lengths: [Feedback.Cue: AVAudioFrameCount] = [:]
        for cue in Feedback.Cue.allCases {
            let buffer = try #require(Feedback.synthesize(cue, format: format))
            #expect(buffer.frameLength > 0)
            lengths[cue] = buffer.frameLength
        }
        #expect(lengths[.step]! > lengths[.move]!)
    }
}
