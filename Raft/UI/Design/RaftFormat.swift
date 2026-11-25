import Foundation

/// Dates and times as the screens show them.
enum RaftFormat {
    nonisolated(unsafe) private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jjmm")
        return formatter
    }()
    nonisolated(unsafe) private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()
    nonisolated(unsafe) private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()

    /// `HH:mm` (or the 12-hour form the system uses).
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// Today / Yesterday / `EEE, MMM d` (date lines, Activity headers).
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.t("activity_list_day_today", "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.t("activity_list_day_yesterday", "Yesterday")
        }
        return dayFormatter.string(from: date)
    }

    /// Home rows: today `HH:mm`, within 7 days `EEE`, else `MMM d`.
    static func listTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return weekdayFormatter.string(from: date)
        }
        return monthDayFormatter.string(from: date)
    }

    /// Activity rows: `now`, `3m ago`, `1h ago` today; `HH:mm` before.
    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if calendar.isDate(date, inSameDayAs: now) {
            if seconds < 60 { return L10n.t("activity_list_time_now", "now") }
            if seconds < 3600 { return L10n.f("activity_list_time_minutes", "%1$dm ago", Int(seconds / 60)) }
            return L10n.f("activity_list_time_hours", "%1$dh ago", Int(seconds / 3600))
        }
        return clock(date)
    }

    /// The full spoken form for VoiceOver.
    static func spoken(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// `248 KB`.
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
