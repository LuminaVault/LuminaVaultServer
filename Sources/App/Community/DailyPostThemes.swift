import Foundation

/// The curated rotation behind the Daily Post: productivity and second-brain
/// themes that fit the app. Each `id` is stored on the day's row, so a theme
/// is not repeated within `DailyPostWorker.themeCooldownDays`. Append new
/// themes at the end — the rotation is by index, so inserting in the middle
/// shifts which theme each future day gets.
struct DailyPostTheme: Sendable, Equatable {
    let id: String
    let title: String
    let angle: String
}

enum DailyPostThemes {
    static let all: [DailyPostTheme] = [
        .init(id: "weekly-review", title: "The weekly review", angle: "Why a short weekly look back beats daily planning marathons."),
        .init(id: "capture-friction", title: "Capture friction", angle: "Ideas die in the gap between noticing and writing down; shrink it."),
        .init(id: "linking-notes", title: "Linking notes", angle: "A note connected to two others is worth more than ten in a folder."),
        .init(id: "resurfacing", title: "Resurfacing old notes", angle: "Notes you never revisit are a graveyard; build in reasons to look back."),
        .init(id: "deep-work-blocks", title: "Deep work blocks", angle: "Protecting one uninterrupted block a day and what fills it."),
        .init(id: "energy-not-time", title: "Manage energy, not time", angle: "Matching tasks to the hours you think best in."),
        .init(id: "inbox-zero-notes", title: "Inbox zero for notes", angle: "Processing captures regularly so the inbox stays a waiting room, not a home."),
        .init(id: "small-next-action", title: "The smallest next action", angle: "Turning a vague project into a step you could do in five minutes."),
        .init(id: "progressive-summarization", title: "Summarise in layers", angle: "Highlight, then highlight the highlights, so future you reads less."),
        .init(id: "writing-to-think", title: "Writing to think", angle: "Drafting as a way to find out what you actually believe."),
        .init(id: "decision-journal", title: "A decision journal", angle: "Writing down why you chose something, so you can learn from how it went."),
        .init(id: "daily-shutdown", title: "The shutdown ritual", angle: "Closing loops at the end of a day so work stops following you home."),
        .init(id: "single-tasking", title: "Single-tasking", angle: "What switching costs and how to notice you are paying it."),
        .init(id: "reading-notes", title: "Notes that survive the book", angle: "Taking reading notes in your own words, not quotes."),
        .init(id: "projects-vs-areas", title: "Projects versus areas", angle: "Separating things with a finish line from things you maintain forever."),
        .init(id: "saying-no", title: "Saying no", angle: "Every yes spends attention; deciding what you will not do."),
        .init(id: "meeting-notes", title: "Meeting notes that matter", angle: "Capturing decisions and owners instead of transcripts."),
        .init(id: "idea-incubation", title: "Letting ideas incubate", angle: "Parking half-formed ideas somewhere you will trip over them again."),
        .init(id: "morning-pages", title: "Morning pages", angle: "Clearing your head on paper before the day fills it."),
        .init(id: "tool-minimalism", title: "Fewer tools", angle: "The cost of spreading your notes across five apps."),
        .init(id: "habit-stacking", title: "Habit stacking", angle: "Attaching a new habit to one you already have."),
        .init(id: "questions-not-topics", title: "Organise by questions", angle: "Filing notes under the questions you are working on, not subjects."),
        .init(id: "done-list", title: "The done list", angle: "Recording what you finished, not just what is left."),
        .init(id: "notification-diet", title: "A notification diet", angle: "Deciding which interruptions earn the right to reach you."),
        .init(id: "learning-in-public", title: "Learning in public", angle: "Sharing rough notes to think better and meet people who care."),
        .init(id: "time-boxing", title: "Time-boxing", angle: "Giving a task a fixed slot so it cannot expand to fill the day."),
        .init(id: "personal-knowledge-garden", title: "Notes as a garden", angle: "Tending a few notes often instead of collecting many once."),
        .init(id: "monthly-reflection", title: "Monthly reflection", angle: "Looking at a month of notes for patterns a week cannot show."),
        .init(id: "context-switching-notes", title: "Notes for future context", angle: "Leaving yourself a breadcrumb before you put work down."),
        .init(id: "rest-as-work", title: "Rest is part of the work", angle: "Why breaks and walks often produce the best ideas."),
        .init(id: "templates", title: "Templates that help", angle: "When a template saves thought and when it replaces it."),
        .init(id: "voice-capture", title: "Capturing by voice", angle: "Speaking thoughts on a walk and turning them into notes later."),
        .init(id: "goal-vs-system", title: "Goals versus systems", angle: "What you do every day matters more than the target you set."),
        .init(id: "ai-as-thinking-partner", title: "AI as a thinking partner", angle: "Using an assistant to question your notes rather than write them."),
        .init(id: "research-trail", title: "Keeping a research trail", angle: "Saving sources and why they mattered while you still remember."),
        .init(id: "two-minute-rule", title: "The two-minute rule", angle: "Doing small things now instead of tracking them."),
        .init(id: "focus-environment", title: "Designing for focus", angle: "Changing your surroundings so the right work is the easy work."),
        .init(id: "evergreen-notes", title: "Evergreen notes", angle: "Writing notes that stay useful long after the project ends."),
        .init(id: "annual-themes", title: "A theme instead of resolutions", angle: "One word for the season that guides many small choices."),
        .init(id: "forgetting-on-purpose", title: "Forgetting on purpose", angle: "Archiving and deleting so what is left is worth finding."),
    ]

    /// The theme for `dayIndex` (days since 1970-01-01): walk the rotation from
    /// that day's slot and take the first theme not used recently.
    static func pick(dayIndex: Int, recentlyUsed: Set<String>) -> DailyPostTheme {
        let count = all.count
        let start = ((dayIndex % count) + count) % count
        for offset in 0 ..< count {
            let theme = all[(start + offset) % count]
            if !recentlyUsed.contains(theme.id) {
                return theme
            }
        }
        return all[start]
    }
}
