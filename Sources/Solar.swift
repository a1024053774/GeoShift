import Foundation

struct ZoneCoordinate: Equatable {
    var latitude: Double
    var longitude: Double
}

enum ZoneLocation {
    static func coordinate(for identifier: String) -> ZoneCoordinate? {
        coordinate(for: identifier, in: systemTable())
    }

    static func coordinate(for identifier: String, in table: String) -> ZoneCoordinate? {
        for line in table.split(whereSeparator: \.isNewline) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[2] == Substring(identifier) else { continue }
            return parse(String(fields[1]))
        }
        return nil
    }

    static func resolved(for timeZone: TimeZone, at date: Date) -> ZoneCoordinate {
        if let known = coordinate(for: timeZone.identifier) {
            return known
        }
        let hours = Double(timeZone.secondsFromGMT(for: date)) / 3600
        return ZoneCoordinate(latitude: 25, longitude: hours * 15)
    }

    static func parse(_ raw: String) -> ZoneCoordinate? {
        let body = raw.dropFirst()
        guard let split = body.firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let latitude = String(raw[..<split])
        let longitude = String(raw[split...])
        guard let lat = component(latitude, degreeDigits: 2),
              let lon = component(longitude, degreeDigits: 3) else {
            return nil
        }
        return ZoneCoordinate(latitude: lat, longitude: lon)
    }

    private static func systemTable() -> String {
        let paths = [
            "/var/db/timezone/zoneinfo/zone.tab",
            "/usr/share/zoneinfo/zone.tab",
        ]
        for path in paths {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                return text
            }
        }
        return ""
    }

    private static func component(_ raw: String, degreeDigits: Int) -> Double? {
        guard let sign = raw.first, sign == "+" || sign == "-" else { return nil }
        let digits = raw.dropFirst()
        let expected = [degreeDigits + 2, degreeDigits + 4]
        guard expected.contains(digits.count), digits.allSatisfy(\.isNumber) else { return nil }
        let degreeEnd = digits.index(digits.startIndex, offsetBy: degreeDigits)
        let minuteEnd = digits.index(degreeEnd, offsetBy: 2)
        guard let degrees = Double(digits[..<degreeEnd]),
              let minutes = Double(digits[degreeEnd..<minuteEnd]) else {
            return nil
        }
        let seconds = minuteEnd < digits.endIndex ? Double(digits[minuteEnd...]) ?? 0 : 0
        let value = degrees + minutes / 60 + seconds / 3600
        return sign == "-" ? -value : value
    }
}

enum SolarDay {
    static func appearance(at date: Date, timeZone: TimeZone, coordinate: ZoneCoordinate) -> DayAppearance {
        switch phase(at: date, timeZone: timeZone, coordinate: coordinate) {
        case .day, .polarDay:
            return .light
        case .night, .polarNight:
            return .dark
        }
    }

    static func nextChangeDescription(after date: Date, timeZone: TimeZone, coordinate: ZoneCoordinate) -> String {
        guard let next = nextTransition(after: date, timeZone: timeZone, coordinate: coordinate) else {
            return appearance(at: date, timeZone: timeZone, coordinate: coordinate) == .light ? "全天浅色" : "全天深色"
        }
        let calendar = ChinaClock.calendar(timeZone)
        let time = clockTime(next.date, timeZone: timeZone)
        let when: String
        if calendar.isDate(next.date, inSameDayAs: date) {
            when = "今天 \(time)"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: date),
                  calendar.isDate(next.date, inSameDayAs: tomorrow) {
            when = "明天 \(time)"
        } else {
            let parts = calendar.dateComponents([.month, .day], from: next.date)
            when = String(format: "%d月%d日 %@", parts.month ?? 0, parts.day ?? 0, time)
        }
        return "\(when) 切换为\(next.appearance.label)"
    }

    static func nextTransition(
        after date: Date,
        timeZone: TimeZone,
        coordinate: ZoneCoordinate
    ) -> (date: Date, appearance: DayAppearance)? {
        let calendar = ChinaClock.calendar(timeZone)
        guard let start = calendar.dateInterval(of: .day, start: date) else { return nil }
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let times = sunTimes(on: day, timeZone: timeZone, coordinate: coordinate)
            let marks: [(Date, DayAppearance)] = [
                times.sunrise.map { ($0, .light) },
                times.sunset.map { ($0, .dark) },
            ].compactMap { $0 }
            if let next = marks.filter({ $0.0 > date }).min(by: { $0.0 < $1.0 }) {
                return next
            }
        }
        return nil
    }

    private enum Phase {
        case day
        case night
        case polarDay
        case polarNight
    }

    private static func phase(at date: Date, timeZone: TimeZone, coordinate: ZoneCoordinate) -> Phase {
        let calendar = ChinaClock.calendar(timeZone)
        guard let start = calendar.dateInterval(of: .day, start: date) else { return .night }
        let times = sunTimes(on: start, timeZone: timeZone, coordinate: coordinate)
        switch (times.sunrise, times.sunset) {
        case let (sunrise?, sunset?):
            return (date >= sunrise && date < sunset) ? .day : .night
        case (nil, nil):
            return times.polarDay ? .polarDay : .polarNight
        default:
            return .night
        }
    }

    private struct SunTimes {
        var sunrise: Date?
        var sunset: Date?
        var polarDay: Bool
    }

    private static func sunTimes(on day: Date, timeZone: TimeZone, coordinate: ZoneCoordinate) -> SunTimes {
        let calendar = ChinaClock.calendar(timeZone)
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayNumber = parts.day,
              let ordinal = calendar.ordinality(of: .day, in: .year, for: day) else {
            return SunTimes(sunrise: nil, sunset: nil, polarDay: false)
        }
        let gamma = 2 * Double.pi / 365 * Double(ordinal - 1)
        let equationOfTime = 229.18 * (
            0.000075
                + 0.001868 * cos(gamma)
                - 0.032077 * sin(gamma)
                - 0.014615 * cos(2 * gamma)
                - 0.040849 * sin(2 * gamma)
        )
        let declination = 0.006918
            - 0.399912 * cos(gamma)
            + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma)
            + 0.00148 * sin(3 * gamma)
        let latitude = coordinate.latitude * .pi / 180
        let zenith = 90.833 * .pi / 180
        let cosineHourAngle = cos(zenith) / (cos(latitude) * cos(declination)) - tan(latitude) * tan(declination)
        if cosineHourAngle > 1 {
            return SunTimes(sunrise: nil, sunset: nil, polarDay: false)
        }
        if cosineHourAngle < -1 {
            return SunTimes(sunrise: nil, sunset: nil, polarDay: true)
        }
        let hourAngle = acos(cosineHourAngle) * 180 / .pi
        let sunriseUTC = 720 - 4 * (coordinate.longitude + hourAngle) - equationOfTime
        let sunsetUTC = 720 - 4 * (coordinate.longitude - hourAngle) - equationOfTime
        return SunTimes(
            sunrise: utcMinutes(sunriseUTC, year: year, month: month, day: dayNumber),
            sunset: utcMinutes(sunsetUTC, year: year, month: month, day: dayNumber),
            polarDay: false
        )
    }

    private static func utcMinutes(_ minutes: Double, year: Int, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let midnight = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        return midnight.addingTimeInterval(minutes * 60)
    }

    private static func clockTime(_ date: Date, timeZone: TimeZone) -> String {
        let parts = ChinaClock.calendar(timeZone).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

private extension Calendar {
    func dateInterval(of component: Component, start date: Date) -> Date? {
        self.dateInterval(of: component, for: date)?.start
    }
}
