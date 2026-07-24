import Foundation

// What lives in the pond. The register here is a quiet person's notebook, not
// a bestiary: concrete, unhurried, no jokes that wear out on the tenth read.
// Junk is never a dud; an old lure is as good a find as a bass.

/// How deep into the pool a catch reached. Tiers only ever open up as a line
/// stays out; nothing closes, so no band can be missed.
nonisolated enum PondTier: Int, Codable, CaseIterable, Sendable {
    case common, uncommon, notable, rare, strange
}

/// The four bands of the real clock, read at reel-in. They tint the water and
/// gate a handful of species; nothing else depends on them.
nonisolated enum PondTimeOfDay: String, Codable, CaseIterable, Sendable {
    case morning, day, evening, night

    static func at(_ date: Date, calendar: Calendar = .current) -> PondTimeOfDay {
        switch calendar.component(.hour, from: date) {
        case 5..<10: return .morning
        case 10..<17: return .day
        case 17..<21: return .evening
        default: return .night
        }
    }

    var name: String { rawValue }
}

/// One thing that can take the hook. `sizes` are whole phrases, not stat
/// blocks: they read the same on the card and in the almanac. A nil `gate`
/// means it can turn up at any hour.
nonisolated struct PondSpecies: Sendable {
    let id: String
    let name: String
    let tier: PondTier
    let flavor: String
    let sizes: [String]
    let gate: [PondTimeOfDay]?

    init(_ id: String, _ name: String, _ tier: PondTier, _ flavor: String, _ sizes: [String], gate: [PondTimeOfDay]? = nil) {
        self.id = id
        self.name = name
        self.tier = tier
        self.flavor = flavor
        self.sizes = sizes
        self.gate = gate
    }

    func fits(_ time: PondTimeOfDay) -> Bool {
        guard let gate else { return true }
        return gate.contains(time)
    }
}

nonisolated enum PondCatalog {
    static let species: [PondSpecies] = [
        // MARK: Common — the pond's whole day, and never a disappointment.
        PondSpecies("minnow", "minnow", .common,
                    "A silver comma, gone the moment it is loose.",
                    ["barely the length of a finger", "small enough to see the light through", "a thumb's length, no more"]),
        PondSpecies("bluegill", "bluegill", .common,
                    "Olive and copper, and mostly fin.",
                    ["a palm's width, flat as a coin", "a hand-span, deep through the body", "young, and all appetite"]),
        PondSpecies("tadpole", "tadpole", .common,
                    "Still deciding what it intends to be.",
                    ["a dark bead with a tail", "legs just started", "no bigger than a fingertip"]),
        PondSpecies("water beetle", "water beetle", .common,
                    "Oil-black, rowing, faintly annoyed.",
                    ["the size of a shirt button", "a thumbnail, and glossy"]),
        PondSpecies("shiner", "shiner", .common,
                    "It takes the light and hands it back.",
                    ["a finger's length", "a hand-span of pure reflection"]),
        PondSpecies("mud minnow", "mud minnow", .common,
                    "Blunt and brown, built for the bottom.",
                    ["a finger's length, thick for its size", "small, and stubborn about it"]),
        PondSpecies("pond snail", "pond snail", .common,
                    "It rode the line up without noticing.",
                    ["a coiled thumbnail", "the size of a pea, and in no hurry"]),
        PondSpecies("dragonfly nymph", "dragonfly nymph", .common,
                    "A folded thing that will be a dragonfly and does not know it yet.",
                    ["an inch of armored patience", "smaller than the hook is long"]),
        PondSpecies("fry", "fry", .common,
                    "Someone's whole next generation, briefly.",
                    ["a scatter of them, translucent", "one, and barely"]),
        PondSpecies("lily pad", "lily pad", .common,
                    "Hooked by the stem, and it came up whole.",
                    ["a saucer of green, dripping", "the size of a spread hand"]),
        PondSpecies("stick", "waterlogged stick", .common,
                    "Heavy as a fish, right up until it isn't.",
                    ["a forearm of soft black wood", "an arm's length, and half bark"]),

        // MARK: Uncommon — a couple of minutes of quiet buys these.
        PondSpecies("perch", "yellow perch", .uncommon,
                    "Barred gold, and it fought the whole way.",
                    ["a hand-span, striped like a wasp", "two hand-spans, heavy in the palm", "a forearm's length, unusual for one"]),
        PondSpecies("sunfish", "pumpkinseed sunfish", .uncommon,
                    "Painted like something that should not be this common.",
                    ["a palm's width of orange and blue", "a hand-span, and bright"]),
        PondSpecies("crayfish", "crayfish", .uncommon,
                    "It let go of the bait, but not of its dignity.",
                    ["a hand-span, claws included", "small, and holding the hook itself"]),
        PondSpecies("small bass", "small bass", .uncommon,
                    "A largemouth that has not grown into its name.",
                    ["a hand-span, and furious", "two hand-spans of green"]),
        PondSpecies("rock bass", "rock bass", .uncommon,
                    "Red-eyed, and it came off the stones.",
                    ["a hand-span, blunt-headed", "a palm's width, mottled"]),
        PondSpecies("chub", "creek chub", .uncommon,
                    "Grey, ordinary, and perfectly made.",
                    ["a hand-span", "a forearm's length, soft-scaled"]),
        PondSpecies("sucker", "white sucker", .uncommon,
                    "All mouth, pointed at the floor of the pond.",
                    ["a forearm's length", "two hand-spans, and cold"]),
        PondSpecies("warmouth", "warmouth", .uncommon,
                    "Brick-brown, and it looks like it is scowling.",
                    ["a hand-span, thick through the head", "a palm's width"]),
        PondSpecies("bullhead", "brown bullhead", .uncommon,
                    "Whiskers first, out of the dark.",
                    ["a forearm's length, smooth as a stone", "two hand-spans, and slick"],
                    gate: [.night, .evening]),

        // MARK: Notable — a quarter hour of the line just sitting there.
        PondSpecies("largemouth", "largemouth bass", .notable,
                    "It came up slow, then all at once.",
                    ["a forearm's length, unhurried", "both hands to hold, and green as moss", "a forearm's length, deep-bellied"]),
        PondSpecies("catfish", "channel catfish", .notable,
                    "It surfaced like a piece of the bottom deciding to leave.",
                    ["an arm's length, pale-bellied", "both hands, and still slipping", "a forearm's length, whiskered"]),
        PondSpecies("koi", "koi", .notable,
                    "White and red. It escaped from somewhere, once, and never said where.",
                    ["a forearm's length, unbothered", "two hands' width of red and white"]),
        PondSpecies("snapper", "snapping turtle", .notable,
                    "It considered the hook, then considered you.",
                    ["a dinner plate with opinions", "a shell the width of two hands"]),
        PondSpecies("carp", "common carp", .notable,
                    "Bronze, ancient-looking, entirely unimpressed.",
                    ["an arm's length, heavy as a bag of flour", "a forearm's length, gold-scaled"]),
        PondSpecies("bowfin", "bowfin", .notable,
                    "Older than the pond, by a long way.",
                    ["an arm's length, muscled the whole way down", "a forearm's length, dark-finned"]),
        PondSpecies("gar", "spotted gar", .notable,
                    "A long green pause with teeth.",
                    ["an arm's length, and mostly nose", "a forearm's length, spotted like a trout's ghost"]),
        PondSpecies("walleye", "walleye", .notable,
                    "Its eyes hold the little light there is.",
                    ["a forearm's length, glass-eyed", "two hand-spans, cold from below"],
                    gate: [.night, .evening]),
        PondSpecies("paddle", "canoe paddle", .notable,
                    "Half-buried, worn smooth on one edge. Somebody used this a lot.",
                    ["an arm's length of grey ash", "a paddle blade, cracked but whole"]),

        // MARK: Rare — an hour and a half, or an afternoon meeting.
        PondSpecies("pike", "northern pike", .rare,
                    "It did not fight so much as reconsider.",
                    ["an arm's length, barred like weed shadow", "longer than your forearm, and thin as a knife"]),
        PondSpecies("eel", "eel", .rare,
                    "It knotted itself around the line and waited to be understood.",
                    ["an arm's length of muscle", "longer than it has any right to be"],
                    gate: [.night]),
        PondSpecies("lure", "old brass lure", .rare,
                    "Still bright. Someone lost this and never stopped thinking about it.",
                    ["brass, thumb-sized, hooks long gone", "a spoon lure, tarnished only at the edges"]),
        PondSpecies("bottle", "bottle with a note in it", .rare,
                    "The cork held. The ink did not, quite.",
                    ["a green bottle, hand-length", "a small bottle, still dry inside"]),
        PondSpecies("trout", "rainbow trout", .rare,
                    "Nothing about this pond explains a trout.",
                    ["a forearm's length, and cold to the touch", "two hand-spans, pink-striped"],
                    gate: [.morning]),
        PondSpecies("sturgeon", "young sturgeon", .rare,
                    "Armored, prehistoric, and about the size of a cat.",
                    ["an arm's length, ridged like a roof", "a forearm's length, and older than it looks"]),
        PondSpecies("watch", "pocket watch", .rare,
                    "Stopped, of course. The case still closes.",
                    ["silver, palm-sized, chain long gone", "a watch the size of a plum, filled with pond"]),
        PondSpecies("spectacles", "pair of spectacles", .rare,
                    "Wire frames, both lenses intact. Someone leaned too far out.",
                    ["thumb-thin wire, bent at one arm", "small, and still folding shut"]),

        // MARK: Strange — half a day, or a night's sleep.
        PondSpecies("albino catfish", "albino catfish", .strange,
                    "White as paper, and it came up without a sound.",
                    ["an arm's length, and faintly luminous", "both hands, pale as candle wax"]),
        PondSpecies("moonlight fish", "fish made of moonlight", .strange,
                    "It was on the line, and then it was only water again.",
                    ["a forearm's length, more or less", "the shape of a fish, and the weight of none"],
                    gate: [.night]),
        PondSpecies("key", "key to something", .strange,
                    "Iron, long-toothed, warm for no reason at all.",
                    ["the length of a finger, and heavy", "palm-sized, and worn smooth at the bow"]),
        PondSpecies("patient snapper", "very patient snapping turtle", .strange,
                    "The same one. It has decided you are part of the pond now.",
                    ["a shell like a car door, moss-backed", "both arms, and entirely unbothered"]),
        PondSpecies("mirror carp", "black mirror carp", .strange,
                    "It watched you the whole time it was out of the water.",
                    ["an arm's length, scaled in plates", "a forearm's length, and it does not blink"]),
        PondSpecies("bell", "small brass bell", .strange,
                    "The clapper is gone. It rings anyway, once, in the hand.",
                    ["the size of a plum, green with age", "thumb-sized, and colder than the water"]),
        PondSpecies("chart fish", "fish with a map on its side", .strange,
                    "The markings are a coastline. It is not one you know.",
                    ["a forearm's length, inked along the flank", "two hand-spans, and the map continues on the other side"]),
        PondSpecies("dawn eel", "silver eel", .strange,
                    "It arrived facing the sunrise and would not be turned around.",
                    ["an arm's length, and bright the whole way", "longer than both hands, mirror-sided"],
                    gate: [.morning]),
        PondSpecies("lantern", "lantern, still dry inside", .strange,
                    "The glass is clean. The wick has been trimmed recently.",
                    ["hand-sized, tin and glass", "a small lantern, not a drop in it"],
                    gate: [.night, .evening])
    ]

    static func species(id: String) -> PondSpecies? {
        species.first { $0.id == id }
    }

    static func species(in tier: PondTier) -> [PondSpecies] {
        species.filter { $0.tier == tier }
    }
}
