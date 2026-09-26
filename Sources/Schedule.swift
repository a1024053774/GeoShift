import Foundation

enum DayAppearance: Equatable {
    case light
    case dark

    var label: String {
        self == .light ? "浅色" : "深色"
    }
}

struct DaySchedule: Equatable {
    var lightMinutes: Int
    var darkMinutes: Int

    static let `default` = DaySchedule(lightMinutes: 7 * 60, darkMinutes: 19 * 60)

    static func load() -> DaySchedule {
        let defaults = UserDefaults.standard
        let light = defaults.object(forKey: Key.lightMinutes) as? Int ?? DaySchedule.default.lightMinutes
        let dark = defaults.object(forKey: Key.darkMinutes) as? Int ?? DaySchedule.default.darkMinutes
        return DaySchedule(lightMinutes: light, darkMinutes: dark).normalized() ?? .default
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(lightMinutes, forKey: Key.lightMinutes)
        defaults.set(darkMinutes, forKey: Key.darkMinutes)
    }

    func normalized() -> DaySchedule? {
        guard (0..<24 * 60).contains(lightMinutes),
              (0..<24 * 60).contains(darkMinutes),
              lightMinutes != darkMinutes else {
            return nil
        }
        return self
    }

    func appearance(atMinutes minutes: Int) -> DayAppearance {
        let minute = ((minutes % 1440) + 1440) % 1440
        if lightMinutes == darkMinutes {
            return .light
        }
        if lightMinutes < darkMinutes {
            return (minute >= lightMinutes && minute < darkMinutes) ? .light : .dark
        }
        return (minute >= lightMinutes || minute < darkMinutes) ? .light : .dark
    }

    func clockText() -> String {
        "\(Self.clock(lightMinutes))–\(Self.clock(darkMinutes))"
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    private enum Key {
        static let lightMinutes = "lightMinutes"
        static let darkMinutes = "darkMinutes"
    }
}

enum ChinaClock {
    static let china = TimeZone(identifier: "Asia/Shanghai")!
    static let sanFrancisco = TimeZone(identifier: "America/Los_Angeles")!

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func chinaCalendar() -> Calendar {
        calendar(china)
    }

    /// Whole offset taken from the system time-zone database, so Pacific Daylight Time is included.
    static func sanFranciscoLag(at date: Date) -> (hours: Int, minutes: Int) {
        let seconds = china.secondsFromGMT(for: date) - sanFrancisco.secondsFromGMT(for: date)
        return (seconds / 3600, abs(seconds) % 3600 / 60)
    }

    static func sanFranciscoUsesDaylightSaving(at date: Date) -> Bool {
        sanFrancisco.isDaylightSavingTime(for: date)
    }

    static func nextSanFranciscoDaylightSavingTransition(after date: Date) -> Date? {
        sanFrancisco.nextDaylightSavingTimeTransition(after: date)
    }

    static func minutesSinceChinaMidnight(at date: Date) -> Int {
        let parts = chinaCalendar().dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func appearance(at date: Date, schedule: DaySchedule) -> DayAppearance {
        schedule.appearance(atMinutes: minutesSinceChinaMidnight(at: date))
    }

    static func menuBarTitle(at date: Date) -> String {
        let parts = chinaCalendar().dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        return String(
            format: "%d月%d日 %@ %02d:%02d",
            parts.month ?? 0,
            parts.day ?? 0,
            weekdayName(parts.weekday),
            parts.hour ?? 0,
            parts.minute ?? 0
        )
    }

    static func zoneLine(at date: Date, timeZone: TimeZone) -> String {
        let parts = calendar(timeZone).dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        return String(
            format: "%d月%d日 %@ %02d:%02d",
            parts.month ?? 0,
            parts.day ?? 0,
            weekdayName(parts.weekday),
            parts.hour ?? 0,
            parts.minute ?? 0
        )
    }

    static func offsetSummary(at date: Date) -> String {
        let saving = sanFrancisco.isDaylightSavingTime(for: date)
        let style: TimeZone.NameStyle = saving ? .daylightSaving : .standard
        let name = sanFrancisco.localizedName(for: style, locale: Locale(identifier: "zh-Hans"))
            ?? (saving ? "夏令时间" : "标准时间")
        let lag = sanFranciscoLag(at: date)
        if lag.minutes == 0 {
            return "\(name) · 比东八区慢 \(lag.hours) 小时"
        }
        return "\(name) · 比东八区慢 \(lag.hours) 小时 \(lag.minutes) 分"
    }

    static func lagSummary(actual: TimeZone, disguise: TimeZone, at date: Date) -> String {
        let seconds = actual.secondsFromGMT(for: date) - disguise.secondsFromGMT(for: date)
        if seconds == 0 {
            return "伪装时区和实际时区现在没有时差"
        }
        let ahead = seconds > 0
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        let relation = ahead ? "慢" : "快"
        if minutes == 0 {
            return "伪装时区比实际时区\(relation) \(hours) 小时"
        }
        return "伪装时区比实际时区\(relation) \(hours) 小时 \(minutes) 分"
    }

    static func nextMinute(after date: Date, timeZone: TimeZone) -> Date {
        let calendar = calendar(timeZone)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if let thisMinute = calendar.date(from: parts),
           let next = calendar.date(byAdding: .minute, value: 1, to: thisMinute),
           next > date {
            return next
        }
        return date.addingTimeInterval(60)
    }

    static func nextMinute(after date: Date) -> Date {
        let calendar = chinaCalendar()
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if let thisMinute = calendar.date(from: parts),
           let next = calendar.date(byAdding: .minute, value: 1, to: thisMinute),
           next > date {
            return next
        }
        return date.addingTimeInterval(60)
    }

    static func nextTransition(after date: Date, schedule: DaySchedule) -> (date: Date, appearance: DayAppearance)? {
        guard schedule.normalized() != nil else { return nil }
        let calendar = chinaCalendar()
        let start = calendar.startOfDay(for: date)
        var candidates: [(Date, DayAppearance)] = []
        for day in 0...1 {
            guard let base = calendar.date(byAdding: .day, value: day, to: start) else { continue }
            for minutes in [schedule.lightMinutes, schedule.darkMinutes] {
                guard let instant = calendar.date(byAdding: .minute, value: minutes, to: base), instant > date else {
                    continue
                }
                candidates.append((instant, appearance(at: instant, schedule: schedule)))
            }
        }
        return candidates.min { $0.0 < $1.0 }
    }

    static func nextChangeDescription(after date: Date, schedule: DaySchedule) -> String {
        guard let next = nextTransition(after: date, schedule: schedule) else {
            return "全天同一外观"
        }
        return "\(relativeDay(next.date, now: date)) 切换为\(next.appearance.label)"
    }

    static func report(at date: Date, schedule: DaySchedule) -> String {
        var lines = [
            "菜单栏 \(menuBarTitle(at: date))",
            "东八区 \(zoneLine(at: date, timeZone: china))",
            "旧金山 \(zoneLine(at: date, timeZone: sanFrancisco))",
            offsetSummary(at: date),
            "外观 \(appearance(at: date, schedule: schedule).label) · \(nextChangeDescription(after: date, schedule: schedule))",
            "系统时区 \(TimeZone.current.identifier)",
        ]
        if let transition = nextSanFranciscoDaylightSavingTransition(after: date) {
            lines.append("下次旧金山夏令时切换 \(zoneLine(at: transition, timeZone: sanFrancisco))")
        }
        return lines.joined(separator: "\n")
    }

    private static func relativeDay(_ date: Date, now: Date) -> String {
        let calendar = chinaCalendar()
        let time = clockTime(date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 \(time)"
        }
        let parts = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%d月%d日 %@", parts.month ?? 0, parts.day ?? 0, time)
    }

    private static func clockTime(_ date: Date) -> String {
        let parts = chinaCalendar().dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func weekdayName(_ weekday: Int?) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = (weekday ?? 1) - 1
        guard names.indices.contains(index) else { return "周?" }
        return names[index]
    }
}
