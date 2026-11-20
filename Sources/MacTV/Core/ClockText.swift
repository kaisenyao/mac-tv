import Foundation

/// 播放时间、时长写成"3:07"，一小时以上"1:02:03"（哔哩哔哩、网易云、影片都用这一个）
func clockText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    let h = total / 3600, m = total % 3600 / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
