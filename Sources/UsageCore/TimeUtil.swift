import Foundation

public enum TimeUtil {
    /// "리셋 2일 후" style countdown text; empty when unknown or already past.
    public static func resetText(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "" }
        let h = Int(s / 3600)
        if h < 1 { return "\(max(1, Int(s / 60)))분 후" }
        if h < 24 { return "\(h)시간 후" }
        return "\(h / 24)일 \(h % 24)시간 후"
    }
}
