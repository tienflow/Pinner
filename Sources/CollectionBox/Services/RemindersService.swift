import EventKit
import Foundation

/// Read model for the todo panel's "today + overdue" overview.
struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let dueDate: Date?
    /// EventKit raw priority: 0 = none, 1 = high, 5 = medium, 9 = low.
    let priority: Int
    let listName: String

    var priorityLabel: String {
        switch priority {
        case 1...4: return "高"
        case 5...8: return "中"
        case 9: return "低"
        default: return ""
        }
    }

    var isOverdue: Bool {
        guard let dueDate else { return false }
        return dueDate < Date()
    }

    /// Overview order: soonest due first (overdue naturally sorts to the top),
    /// no-due reminders last, ties broken by title.
    static func overviewOrder(_ lhs: ReminderItem, _ rhs: ReminderItem) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (l?, r?): return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return lhs.title < rhs.title
        }
    }
}

enum RemindersError: LocalizedError {
    case notAuthorized
    case emptyTitle
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "未获得提醒事项访问权限"
        case .emptyTitle: return "标题不能为空"
        case .saveFailed(let reason): return "写入提醒事项失败：\(reason)"
        }
    }
}

/// EventKit wrapper for the quick-capture panel: authorization, task creation,
/// and the today/overdue overview fetch.
///
/// One shared `EKEventStore` for the process lifetime — recreating the store
/// re-triggers the TCC authorization prompt.
@MainActor
final class RemindersService {
    static let shared = RemindersService()

    private let store = EKEventStore()

    private init() {}

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .fullAccess, .writeOnly: return true
        default: return false
        }
    }

    /// Prompts on first call; afterwards reflects the stored decision.
    func requestAccess() async -> Bool {
        switch authorizationStatus {
        case .fullAccess, .writeOnly:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                store.requestFullAccessToReminders { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    /// Reminder list titles — used for the list picker and LLM prompt context.
    func listNames() -> [String] {
        store.calendars(for: .reminder).map(\.title).sorted()
    }

    /// Writes one reminder. Returns the calendar item identifier.
    @discardableResult
    func createTask(title: String, due: Date?, priority: Int, list: String?) throws -> String {
        guard isAuthorized else { throw RemindersError.notAuthorized }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemindersError.emptyTitle }

        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        reminder.priority = priority
        if let list, !list.isEmpty,
           let calendar = store.calendars(for: .reminder).first(where: { $0.title == list }) {
            reminder.calendar = calendar
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        do {
            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        } catch {
            throw RemindersError.saveFailed(error.localizedDescription)
        }
    }

    /// Marks a reminder completed or incomplete by its calendar item identifier.
    func setTaskCompleted(id: String, completed: Bool = true) throws {
        guard isAuthorized else { throw RemindersError.notAuthorized }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.saveFailed("未找到对应待办事项")
        }
        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersError.saveFailed(error.localizedDescription)
        }
    }

    /// Incomplete reminders due on or before today, plus no-due-date reminders.
    /// Filters out completed reminders and future reminders.
    func fetchTodayAndOverdue() async -> [ReminderItem] {
        guard isAuthorized else { return [] }
        store.refreshSourcesIfNecessary()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return [] }
        let calendars = store.calendars(for: .reminder)
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).compactMap { reminder -> ReminderItem? in
                    guard !reminder.isCompleted else { return nil }
                    let due = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
                    // Exclude future tasks (due after end of today)
                    if let due, due >= endOfToday {
                        return nil
                    }
                    return ReminderItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "",
                        dueDate: due,
                        priority: reminder.priority,
                        listName: reminder.calendar.title
                    )
                }
                continuation.resume(returning: items.sorted(by: ReminderItem.overviewOrder))
            }
        }
    }
}
