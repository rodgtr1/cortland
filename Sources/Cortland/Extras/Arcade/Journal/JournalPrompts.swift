import Foundation

/// Which pool a prompt belongs to. The pool name is written into the entry
/// block header, so these raw values are part of the file format: renaming one
/// rewrites history's vocabulary. Don't.
nonisolated enum JournalPool: String, Codable, Equatable, Sendable, CaseIterable {
    case recenter
    case unload
    case create
    case reflect
}

/// What a prompt's size is counted in. Character prompts count `String.count`
/// (graphemes, so an emoji or an accented letter is one character); word
/// prompts count whitespace-separated tokens.
nonisolated enum JournalLimitUnit: String, Codable, Equatable, Sendable {
    case characters
    case words

    var label: String {
        switch self {
        case .characters: return "characters"
        case .words: return "words"
        }
    }
}

/// One bounded writing prompt: something to notice, and how much room to
/// notice it in. The size is a promise of closure, not a quota.
nonisolated struct JournalPrompt: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let pool: JournalPool
    let text: String
    let limit: Int
    let unit: JournalLimitUnit
}

/// The three doors the picker offers. Reflect is its own door on purpose: the
/// deep pool is reached only by asking for it, never served by default and
/// never by any automatic path.
nonisolated enum JournalDoor: Int, Codable, Equatable, Sendable, CaseIterable {
    case clear = 1
    case make = 2
    case reflect = 3

    var label: String {
        switch self {
        case .clear: return "clear my head"
        case .make: return "make something"
        case .reflect: return "reflect"
        }
    }
}

/// The prompt library. Ground rules for additions: restraint over cleverness,
/// concrete over abstract, and nothing that wears out on the tenth read. The
/// weight is deliberately uneven by pool. Recenter and Unload are small enough
/// to answer with one hand still on the keyboard; Create asks for a few
/// sentences of something that is nobody's business but yours. Mortality,
/// regret, and identity questions belong in Reflect and nowhere else: those
/// are heavy, and you only meet them by choosing door 3.
nonisolated enum JournalPrompts {
    static let all: [JournalPrompt] = recenter + unload + create + reflect

    static func pool(_ pool: JournalPool) -> [JournalPrompt] {
        all.filter { $0.pool == pool }
    }

    // MARK: - Clear my head, door 1

    /// Work-adjacent, near-zero switching cost: you can answer one of these
    /// without leaving the frame of mind you were already in.
    static let recenter: [JournalPrompt] = [
        JournalPrompt(id: "recenter-01", pool: .recenter,
                      text: "What are you hoping this agent run accomplishes?",
                      limit: 150, unit: .characters),
        JournalPrompt(id: "recenter-02", pool: .recenter,
                      text: "What is one decision you already know the answer to?",
                      limit: 200, unit: .characters),
        JournalPrompt(id: "recenter-03", pool: .recenter,
                      text: "Name one thing that has gone well today.",
                      limit: 100, unit: .characters),
        JournalPrompt(id: "recenter-04", pool: .recenter,
                      text: "What do you need less of this afternoon?",
                      limit: 120, unit: .characters),
        JournalPrompt(id: "recenter-05", pool: .recenter,
                      text: "What is the next small thing, not the next big thing?",
                      limit: 30, unit: .words),
        JournalPrompt(id: "recenter-06", pool: .recenter,
                      text: "Which open loop would you close first if you could only close one?",
                      limit: 200, unit: .characters),
        JournalPrompt(id: "recenter-07", pool: .recenter,
                      text: "What are you actually waiting on right now?",
                      limit: 25, unit: .words),
        JournalPrompt(id: "recenter-08", pool: .recenter,
                      text: "Describe the task in front of you in plain words, as if to a friend.",
                      limit: 250, unit: .characters),
        JournalPrompt(id: "recenter-09", pool: .recenter,
                      text: "What would make the next hour feel unhurried?",
                      limit: 180, unit: .characters),
        JournalPrompt(id: "recenter-10", pool: .recenter,
                      text: "Name one thing you can stop carrying for the rest of the day.",
                      limit: 150, unit: .characters),
        JournalPrompt(id: "recenter-11", pool: .recenter,
                      text: "What did you learn in the last hour, however small?",
                      limit: 40, unit: .words),
        JournalPrompt(id: "recenter-12", pool: .recenter,
                      text: "What is working well enough to leave alone?",
                      limit: 160, unit: .characters),
        JournalPrompt(id: "recenter-13", pool: .recenter,
                      text: "Which part of today has your attention that does not deserve it?",
                      limit: 220, unit: .characters),
        JournalPrompt(id: "recenter-14", pool: .recenter,
                      text: "What would done for today look like?",
                      limit: 200, unit: .characters),
        JournalPrompt(id: "recenter-15", pool: .recenter,
                      text: "What is the smallest version of the thing you are putting off?",
                      limit: 35, unit: .words)
    ]

    /// Attention residue: the things still running in the background of a head
    /// that has been supervising machines all day.
    static let unload: [JournalPrompt] = [
        JournalPrompt(id: "unload-01", pool: .unload,
                      text: "What are you avoiding thinking about?",
                      limit: 200, unit: .characters),
        JournalPrompt(id: "unload-02", pool: .unload,
                      text: "Capture the last thought you had before this prompt appeared.",
                      limit: 150, unit: .characters),
        JournalPrompt(id: "unload-03", pool: .unload,
                      text: "What currently feels unfinished outside of work?",
                      limit: 250, unit: .characters),
        JournalPrompt(id: "unload-04", pool: .unload,
                      text: "Describe your mood as weather.",
                      limit: 100, unit: .characters),
        JournalPrompt(id: "unload-05", pool: .unload,
                      text: "What has been rattling around your head today?",
                      limit: 30, unit: .words),
        JournalPrompt(id: "unload-06", pool: .unload,
                      text: "Put down the thing you keep almost saying.",
                      limit: 220, unit: .characters),
        JournalPrompt(id: "unload-07", pool: .unload,
                      text: "Where does your attention go when it wanders off?",
                      limit: 40, unit: .words),
        JournalPrompt(id: "unload-08", pool: .unload,
                      text: "Name the low hum in the background of today.",
                      limit: 120, unit: .characters),
        JournalPrompt(id: "unload-09", pool: .unload,
                      text: "What did you read or hear this week that has not let go?",
                      limit: 250, unit: .characters),
        JournalPrompt(id: "unload-10", pool: .unload,
                      text: "Describe the tension in your body, wherever it is sitting.",
                      limit: 150, unit: .characters),
        JournalPrompt(id: "unload-11", pool: .unload,
                      text: "What is one thing you would rather not have to decide?",
                      limit: 200, unit: .characters),
        JournalPrompt(id: "unload-12", pool: .unload,
                      text: "Write the sentence you would say if someone asked how you really are.",
                      limit: 180, unit: .characters),
        JournalPrompt(id: "unload-13", pool: .unload,
                      text: "What noise, literal or otherwise, would you turn down first?",
                      limit: 20, unit: .words),
        JournalPrompt(id: "unload-14", pool: .unload,
                      text: "Empty your pockets: whatever is on your mind, in no order.",
                      limit: 250, unit: .characters),
        JournalPrompt(id: "unload-15", pool: .unload,
                      text: "What have you been meaning to look up and never do?",
                      limit: 25, unit: .words)
    ]

    // MARK: - Make something, door 2

    /// The palate cleanser proper: expressive, outward, and entirely the
    /// author's own. Nothing here is about work, and nothing here has a right
    /// answer to be evaluated against.
    static let create: [JournalPrompt] = [
        JournalPrompt(id: "create-01", pool: .create,
                      text: "Write your favorite scene from the most recent book you read.",
                      limit: 500, unit: .characters),
        JournalPrompt(id: "create-02", pool: .create,
                      text: "Describe the room without using visual details.",
                      limit: 350, unit: .characters),
        JournalPrompt(id: "create-03", pool: .create,
                      text: "Describe an imaginary shop you would visit but never work in.",
                      limit: 350, unit: .characters),
        JournalPrompt(id: "create-04", pool: .create,
                      text: "Write about a place where you naturally slow down.",
                      limit: 100, unit: .words),
        JournalPrompt(id: "create-05", pool: .create,
                      text: "Write about something you own that carries a memory.",
                      limit: 400, unit: .characters),
        JournalPrompt(id: "create-06", pool: .create,
                      text: "Describe a conversation you still remember for no obvious reason.",
                      limit: 125, unit: .words),
        JournalPrompt(id: "create-07", pool: .create,
                      text: "Write one sentence you wish someone had told you at 25.",
                      limit: 350, unit: .characters),
        JournalPrompt(id: "create-08", pool: .create,
                      text: "Describe a meal you remember better than the occasion around it.",
                      limit: 450, unit: .characters),
        JournalPrompt(id: "create-09", pool: .create,
                      text: "Write the opening paragraph of a book you would like to read.",
                      limit: 600, unit: .characters),
        JournalPrompt(id: "create-10", pool: .create,
                      text: "Describe a stranger you saw today as though they were a character.",
                      limit: 75, unit: .words),
        JournalPrompt(id: "create-11", pool: .create,
                      text: "Write about weather you have been out in and not minded.",
                      limit: 500, unit: .characters),
        JournalPrompt(id: "create-12", pool: .create,
                      text: "Describe a machine or tool you have real affection for.",
                      limit: 400, unit: .characters),
        JournalPrompt(id: "create-13", pool: .create,
                      text: "Write about a road you could drive with your eyes closed.",
                      limit: 150, unit: .words),
        JournalPrompt(id: "create-14", pool: .create,
                      text: "Describe a sound you would keep if you could only keep one.",
                      limit: 350, unit: .characters),
        JournalPrompt(id: "create-15", pool: .create,
                      text: "Write about the last time you were somewhere entirely new.",
                      limit: 800, unit: .characters),
        JournalPrompt(id: "create-16", pool: .create,
                      text: "Describe a small ritual of yours to someone who has never seen it.",
                      limit: 90, unit: .words),
        JournalPrompt(id: "create-17", pool: .create,
                      text: "Write about a house you have never lived in but can picture exactly.",
                      limit: 120, unit: .words)
    ]

    // MARK: - Reflect, door 3

    /// The deep pool. Bigger rooms, longer horizons, and the only place the
    /// heavy questions live. Nothing routes here on its own.
    static let reflect: [JournalPrompt] = [
        JournalPrompt(id: "reflect-01", pool: .reflect,
                      text: "What does your career look like at 52?",
                      limit: 300, unit: .words),
        JournalPrompt(id: "reflect-02", pool: .reflect,
                      text: "What does 'enough' look like for you professionally?",
                      limit: 300, unit: .words),
        JournalPrompt(id: "reflect-03", pool: .reflect,
                      text: "Describe the kind of person you hope your children remember.",
                      limit: 350, unit: .words),
        JournalPrompt(id: "reflect-04", pool: .reflect,
                      text: "Describe your ideal ordinary weekday ten years from now.",
                      limit: 300, unit: .words),
        JournalPrompt(id: "reflect-05", pool: .reflect,
                      text: "Imagine yourself at 70 looking back at this period. What mattered?",
                      limit: 400, unit: .words),
        JournalPrompt(id: "reflect-06", pool: .reflect,
                      text: "Describe three eras of your adult life and what distinguished them.",
                      limit: 400, unit: .words),
        JournalPrompt(id: "reflect-07", pool: .reflect,
                      text: "What do you want to remain unchanged over the next five years?",
                      limit: 250, unit: .words),
        JournalPrompt(id: "reflect-08", pool: .reflect,
                      text: "What work would you still do if no one ever saw it?",
                      limit: 300, unit: .words),
        JournalPrompt(id: "reflect-09", pool: .reflect,
                      text: "Describe a version of your life you did not choose.",
                      limit: 350, unit: .words),
        JournalPrompt(id: "reflect-10", pool: .reflect,
                      text: "What have you changed your mind about in the last ten years?",
                      limit: 300, unit: .words),
        JournalPrompt(id: "reflect-11", pool: .reflect,
                      text: "Who has shaped how you work, and what did they actually teach you?",
                      limit: 350, unit: .words),
        JournalPrompt(id: "reflect-12", pool: .reflect,
                      text: "What would you want said about how you spent your attention?",
                      limit: 300, unit: .words),
        JournalPrompt(id: "reflect-13", pool: .reflect,
                      text: "Describe what you are building toward, if anything.",
                      limit: 250, unit: .words),
        JournalPrompt(id: "reflect-14", pool: .reflect,
                      text: "What do you owe your future self, and what does your past self owe you?",
                      limit: 200, unit: .words),
        JournalPrompt(id: "reflect-15", pool: .reflect,
                      text: "Describe the ten years behind you to someone who last saw you then.",
                      limit: 400, unit: .words)
    ]
}
