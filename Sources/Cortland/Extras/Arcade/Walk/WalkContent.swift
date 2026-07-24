import Foundation

// The words. This file is the soul of The Walk: the register is a field
// notebook, not a fantasy novel. Spare, concrete, unhurried. No exclamation
// marks, no purple prose, no second-person commands. Every line should read
// like something a quiet person actually noticed and set down.

/// The places the walk drifts through. A biome lasts a seeded while, then
/// gives way to a plausible neighbor along `neighbors`; the landscape never
/// jumps from coast to hill crest without the ground in between.
nonisolated enum WalkBiome: String, Codable, CaseIterable, Sendable {
    case meadow, birchWood, pineForest, riverbank, coast, moor
    case orchard, oldRoad, hedgerow, hillCrest, marsh, fallowField

    var name: String {
        switch self {
        case .meadow: return "meadow"
        case .birchWood: return "birch wood"
        case .pineForest: return "pine forest"
        case .riverbank: return "riverbank"
        case .coast: return "coast"
        case .moor: return "moor"
        case .orchard: return "orchard"
        case .oldRoad: return "old road"
        case .hedgerow: return "hedgerow"
        case .hillCrest: return "hill crest"
        case .marsh: return "marsh"
        case .fallowField: return "fallow field"
        }
    }

    /// A rough landscape graph. Each biome borders three to five others; the
    /// whole thing is connected, so a long enough walk can reach anywhere.
    var neighbors: [WalkBiome] {
        switch self {
        case .meadow: return [.hedgerow, .orchard, .fallowField, .oldRoad, .birchWood, .riverbank]
        case .birchWood: return [.meadow, .pineForest, .riverbank, .hedgerow]
        case .pineForest: return [.birchWood, .moor, .hillCrest, .riverbank]
        case .riverbank: return [.birchWood, .pineForest, .marsh, .coast, .meadow]
        case .coast: return [.riverbank, .moor, .marsh]
        case .moor: return [.pineForest, .hillCrest, .coast, .fallowField]
        case .orchard: return [.meadow, .hedgerow, .oldRoad]
        case .oldRoad: return [.meadow, .orchard, .hedgerow, .fallowField, .hillCrest]
        case .hedgerow: return [.meadow, .orchard, .oldRoad, .birchWood, .fallowField]
        case .hillCrest: return [.pineForest, .moor, .oldRoad]
        case .marsh: return [.riverbank, .coast, .fallowField]
        case .fallowField: return [.meadow, .oldRoad, .hedgerow, .moor, .marsh]
        }
    }

    /// One-sentence observations of the place. Templates may carry a single
    /// `{time}` slot, filled from `WalkContent.timeWords`. At least five each;
    /// most have more, so back-to-back steps stay fresh.
    var templates: [String] {
        switch self {
        case .meadow:
            return [
                "The meadow is all seed-heads and slow air.",
                "Grass to the knee, bent one way by an old wind.",
                "{time}, and nothing in the field moves but insects.",
                "A skylark somewhere up and out of sight.",
                "The path is a parting in the grass, no more than that.",
                "Clover and vetch, and the dry sound of grasshoppers.",
                "The ground rises a little, then thinks better of it."
            ]
        case .birchWood:
            return [
                "The birches thin out here. Somewhere off to the left, water.",
                "White trunks, and the light coming through in pieces.",
                "Leaf litter underfoot, years of it, soft.",
                "{time}, and the wood holds its own quiet.",
                "A birch has come down across the way, long dead.",
                "The canopy is thin enough to see sky through.",
                "Bark peeling in papery curls, catching what light there is."
            ]
        case .pineForest:
            return [
                "The pines close in. The air goes still and resinous.",
                "Needles deaden every step to nothing.",
                "The trunks run straight up into shadow.",
                "Little grows down here; the ground is bare and brown.",
                "{time}, and the forest keeps the cold of the night before.",
                "A branch settles somewhere overhead, then nothing.",
                "The way is marked only by the absence of trees."
            ]
        case .riverbank:
            return [
                "The river runs low and brown along the bank.",
                "Reeds lean out over the water, doubled in it.",
                "The path follows the water, or the water follows it.",
                "A moorhen crosses the current and thinks better of it.",
                "{time}, and the river pulls at a caught branch.",
                "Wet stones, and the smell of river mud.",
                "The bank has slumped here, roots bared to the air."
            ]
        case .coast:
            return [
                "The land gives out to shingle and grey water.",
                "Wind off the sea, steady and salt.",
                "The tide is out; the flats shine to the far edge.",
                "Gulls work the wrack line, unbothered.",
                "{time}, and the sea is the color of the sky.",
                "Marram grass holds the dune together, barely.",
                "A groyne runs down into the water, black with weed."
            ]
        case .moor:
            return [
                "The moor opens out, heather to every edge.",
                "Peat holds the wet, and the ground gives underfoot.",
                "Nothing tall grows here. The wind sees to that.",
                "A curlew calls once, far off, and does not again.",
                "{time}, and the light lies flat across the tops.",
                "Old bones of stone break through the heather.",
                "The path is a darker line worn into dark ground."
            ]
        case .orchard:
            return [
                "Old apple trees, unpruned, going their own way.",
                "Windfalls in the grass, more than the wasps can want.",
                "The rows still hold, though the trees have forgotten them.",
                "Lichen furs the north side of every trunk.",
                "{time}, and the orchard smells of cider gone to ground.",
                "A ladder left against a tree, half grown into it.",
                "Bruised fruit underfoot, sweet and turning."
            ]
        case .oldRoad:
            return [
                "An old road, metalled once, grass up the middle now.",
                "The verge is deep in cow parsley and dock.",
                "A milestone, its lettering worn past reading.",
                "The tarmac gives way to hardcore, then to track.",
                "{time}, and the road runs straight for no clear reason.",
                "Telegraph poles march off, the wires long down.",
                "The camber still throws the rain to the sides."
            ]
        case .hedgerow:
            return [
                "A gate in the hedgerow, open just enough.",
                "The hedge is hawthorn, laid a long time back.",
                "Between fields, the path keeps to the hedge's shade.",
                "Old man's beard smothers the top of the hedge.",
                "{time}, and something shifts in the hedge bottom, unseen.",
                "A stile, its step worn to a shallow bowl.",
                "The hedge breaks a moment on more of the same."
            ]
        case .hillCrest:
            return [
                "The ground levels at the top. The land falls away all round.",
                "Up here the wind has the last word.",
                "A trig point, chipped, its metal cap long gone.",
                "The path runs the spine of the hill, thin and sure.",
                "{time}, and the far fields go blue with distance.",
                "Nothing between here and the weather but air.",
                "A cairn, added to by hands over years."
            ]
        case .marsh:
            return [
                "The path turns to boardwalk over standing water.",
                "Reeds close overhead; the way narrows to a slot.",
                "Everything here is the business of water and mud.",
                "A heron lifts, unhurried, and resettles further off.",
                "{time}, and the marsh breaks the surface in slow rounds.",
                "Sedge and rush, and the give of wet ground.",
                "Black water between the tussocks, still as glass."
            ]
        case .fallowField:
            return [
                "A field left to itself, thistle and ragwort taking hold.",
                "Last year's stubble, gone soft and grey.",
                "The plough lines still show under the weeds.",
                "A hare sits up in the middle distance, then is gone.",
                "{time}, and the field hums with nothing in particular.",
                "Charlock has yellowed one corner entirely.",
                "The gateway is churned to dried ruts, hard as stone."
            ]
        }
    }
}

/// A slow Markov chain over the sky. Weather shifts along `neighbors` every
/// ten to twenty-five steps and colors the walk through `inflections`, which
/// are dropped in as an occasional second sentence.
nonisolated enum WalkWeather: String, Codable, CaseIterable, Sendable {
    case clear, highCloud, overcast, lightRain, mist, wind, lateSun

    var name: String {
        switch self {
        case .clear: return "clear"
        case .highCloud: return "high cloud"
        case .overcast: return "overcast"
        case .lightRain: return "light rain"
        case .mist: return "mist"
        case .wind: return "wind picking up"
        case .lateSun: return "late sun"
        }
    }

    var neighbors: [WalkWeather] {
        switch self {
        case .clear: return [.highCloud, .lateSun, .mist]
        case .highCloud: return [.clear, .overcast, .wind, .lateSun]
        case .overcast: return [.highCloud, .lightRain, .mist, .wind]
        case .lightRain: return [.overcast, .mist]
        case .mist: return [.overcast, .lightRain, .clear]
        case .wind: return [.highCloud, .overcast, .clear]
        case .lateSun: return [.clear, .highCloud]
        }
    }

    var inflections: [String] {
        switch self {
        case .clear:
            return ["The sky is clean to the edges.",
                    "Blue, and no cloud to speak of.",
                    "The sun is plain and warm.",
                    "Not a cloud, and the light hard and clear.",
                    "The blue runs on to the far hills."]
        case .highCloud:
            return ["High cloud has drawn a film over the sun.",
                    "The light is bright but without edges.",
                    "A mackerel sky, going nowhere.",
                    "The sun is a pale coin behind the haze.",
                    "Thin cloud, and the day gone soft."]
        case .overcast:
            return ["The cloud is low and unbroken.",
                    "Flat grey light, and no shadow to it.",
                    "The sky has closed over.",
                    "Grey to every horizon, and still.",
                    "The day holds its breath under the cloud."]
        case .lightRain:
            return ["Fine rain, more felt than seen.",
                    "Rain ticks on the leaves.",
                    "The path has darkened with the wet.",
                    "A soft rain, straight down and quiet.",
                    "Everything wears a skin of water now."]
        case .mist:
            return ["Mist has taken the distance.",
                    "The far things are gone in white.",
                    "Anything past a stone's throw is guesswork.",
                    "The world closes to a small grey room.",
                    "Mist beads cold on every thread."]
        case .wind:
            return ["The wind is getting up.",
                    "A gust worries at the grass.",
                    "The air has an edge it did not have.",
                    "The wind leans on everything, steady.",
                    "Something loose is knocking, off in the wind."]
        case .lateSun:
            return ["The light has gone long and gold.",
                    "Late sun, and the shadows reach.",
                    "The day is turning toward its end.",
                    "Everything is edged in low gold light.",
                    "The sun sits fat and low in the west."]
        }
    }
}

/// A small concrete thing come upon along the way. `weight` tiers how often it
/// turns up (common, uncommon, rare) without ever naming the tier; `biomes`
/// nil means it can appear anywhere, otherwise only where it belongs.
nonisolated struct WalkFinding: Sendable {
    let text: String
    let weight: Int
    let biomes: Set<WalkBiome>?

    func fits(_ biome: WalkBiome) -> Bool {
        guard let biomes else { return true }
        return biomes.contains(biome)
    }
}

nonisolated enum WalkContent {
    /// Filled into any template carrying a `{time}` slot. Each reads correctly
    /// at the head of its sentence.
    static let timeWords = [
        "First light", "Early on", "Midmorning", "Midday", "Past noon",
        "Midafternoon", "Late in the day", "Toward evening"
    ]

    /// Occasionally tacked on as a quiet second sentence, sparingly, to vary
    /// the rhythm between steps.
    static let connectives = [
        "The path goes on.",
        "No one has come this way in a while.",
        "It is very quiet.",
        "Somewhere, a dog, and then not.",
        "The way is easy here.",
        "A little further, then."
    ]

    static let weightCommon = 3
    static let weightUncommon = 2
    static let weightRare = 1

    /// Sixty-odd findings. Shared ones first, then biome-bound ones grouped by
    /// where they make sense.
    static let findings: [WalkFinding] = [
        // Shared, common
        WalkFinding(text: "a feather, grey, and no bird in sight", weight: weightCommon, biomes: nil),
        WalkFinding(text: "a snail shell, empty and whole", weight: weightCommon, biomes: nil),
        WalkFinding(text: "a stone worn flat by nothing that shows", weight: weightCommon, biomes: nil),
        WalkFinding(text: "a scatter of rabbit droppings, fresh", weight: weightCommon, biomes: nil),
        WalkFinding(text: "the print of a deer in soft ground", weight: weightCommon, biomes: nil),
        WalkFinding(text: "a spider's web strung with the last of the wet", weight: weightCommon, biomes: nil),
        WalkFinding(text: "a beetle crossing the path with purpose", weight: weightCommon, biomes: nil),
        WalkFinding(text: "a length of old fence wire, coiled by hand", weight: weightCommon, biomes: nil),
        // Shared, uncommon
        WalkFinding(text: "a coin so worn its face is a rumor", weight: weightUncommon, biomes: nil),
        WalkFinding(text: "a boot, single, long past its pair", weight: weightUncommon, biomes: nil),
        WalkFinding(text: "a bird's nest come down whole, unlined", weight: weightUncommon, biomes: nil),
        WalkFinding(text: "a knot of sheep's wool caught on a thorn", weight: weightUncommon, biomes: nil),
        WalkFinding(text: "a fox skull, clean and small", weight: weightUncommon, biomes: nil),
        WalkFinding(text: "a horseshoe rusted to a wafer", weight: weightUncommon, biomes: nil),
        WalkFinding(text: "a marble in the dirt, clouded glass", weight: weightUncommon, biomes: nil),
        // Shared, rare
        WalkFinding(text: "a key, iron, to no lock anywhere near", weight: weightRare, biomes: nil),
        WalkFinding(text: "a line of stones set by someone, meaning gone", weight: weightRare, biomes: nil),
        WalkFinding(text: "an old coin, silver under the black", weight: weightRare, biomes: nil),
        WalkFinding(text: "a ring of paler grass, a fairy ring", weight: weightRare, biomes: nil),
        // Meadow
        WalkFinding(text: "a grasshopper the exact green of the stem", weight: weightCommon, biomes: [.meadow]),
        WalkFinding(text: "a skylark's nest, four eggs, left well alone", weight: weightCommon, biomes: [.meadow]),
        WalkFinding(text: "a hare's form pressed into the grass, still warm", weight: weightUncommon, biomes: [.meadow, .fallowField]),
        WalkFinding(text: "a slow-worm, bronze, there and then not", weight: weightRare, biomes: [.meadow, .hedgerow]),
        // Birch wood
        WalkFinding(text: "a curl of birch bark, white as paper", weight: weightCommon, biomes: [.birchWood]),
        WalkFinding(text: "bracket fungus stepped up a dead trunk", weight: weightCommon, biomes: [.birchWood, .pineForest]),
        WalkFinding(text: "a jay's feather, that impossible blue", weight: weightUncommon, biomes: [.birchWood, .pineForest]),
        WalkFinding(text: "a ring of small pale mushrooms, up overnight", weight: weightRare, biomes: [.birchWood, .meadow]),
        // Pine forest
        WalkFinding(text: "a pine cone opened wide and dry", weight: weightCommon, biomes: [.pineForest]),
        WalkFinding(text: "an owl pellet, grey with small bones", weight: weightCommon, biomes: [.pineForest, .moor]),
        WalkFinding(text: "resin bled amber down the bark", weight: weightUncommon, biomes: [.pineForest]),
        WalkFinding(text: "a kill plucked in a neat ring of feathers", weight: weightRare, biomes: [.pineForest]),
        // Riverbank
        WalkFinding(text: "a heron's track in the mud, three toes wide", weight: weightCommon, biomes: [.riverbank, .marsh]),
        WalkFinding(text: "a mussel shell, blue-black on the inside", weight: weightCommon, biomes: [.riverbank, .coast]),
        WalkFinding(text: "a kingfisher gone downstream, only the blue of it", weight: weightUncommon, biomes: [.riverbank]),
        WalkFinding(text: "an eel-trap, withy-woven, snagged on a root", weight: weightRare, biomes: [.riverbank, .marsh]),
        // Coast
        WalkFinding(text: "a gull's feather stuck upright in the sand", weight: weightCommon, biomes: [.coast]),
        WalkFinding(text: "a crab's back, emptied clean", weight: weightCommon, biomes: [.coast]),
        WalkFinding(text: "sea glass, green, its edges gone soft", weight: weightCommon, biomes: [.coast]),
        WalkFinding(text: "a cuttlebone, white and light as nothing", weight: weightUncommon, biomes: [.coast]),
        WalkFinding(text: "a mermaid's purse, dry and curled", weight: weightUncommon, biomes: [.coast]),
        WalkFinding(text: "a great rib bone, half in the shingle", weight: weightRare, biomes: [.coast]),
        // Moor
        WalkFinding(text: "a sprig of bell heather, still in flower", weight: weightCommon, biomes: [.moor]),
        WalkFinding(text: "cotton grass nodding over a wet patch", weight: weightCommon, biomes: [.moor]),
        WalkFinding(text: "a grouse feather, barred brown", weight: weightUncommon, biomes: [.moor]),
        WalkFinding(text: "a boundary stone, initials cut a century back", weight: weightRare, biomes: [.moor, .hillCrest]),
        // Orchard
        WalkFinding(text: "a windfall with one bite taken by a bird", weight: weightCommon, biomes: [.orchard]),
        WalkFinding(text: "a wasp gone deep into a split plum", weight: weightCommon, biomes: [.orchard]),
        WalkFinding(text: "a ladder rung rotted through in the grass", weight: weightUncommon, biomes: [.orchard]),
        WalkFinding(text: "a name and a year carved in an apple trunk", weight: weightRare, biomes: [.orchard]),
        // Old road
        WalkFinding(text: "a fragment of clay pipe, just the stem", weight: weightCommon, biomes: [.oldRoad]),
        WalkFinding(text: "a hubcap mossed over at the verge", weight: weightCommon, biomes: [.oldRoad]),
        WalkFinding(text: "a milestone laid flat, the miles still legible", weight: weightUncommon, biomes: [.oldRoad]),
        WalkFinding(text: "a cat's-eye prised from the road, staring up", weight: weightRare, biomes: [.oldRoad]),
        // Hedgerow
        WalkFinding(text: "a blackbird's nest deep in the thorn", weight: weightCommon, biomes: [.hedgerow]),
        WalkFinding(text: "sloes going blue on the blackthorn", weight: weightCommon, biomes: [.hedgerow]),
        WalkFinding(text: "a dormouse nest, woven grass, the size of a fist", weight: weightUncommon, biomes: [.hedgerow]),
        WalkFinding(text: "a smooth gap worn under the hedge by hares", weight: weightRare, biomes: [.hedgerow, .fallowField]),
        // Hill crest
        WalkFinding(text: "a raven's feather, oily black", weight: weightCommon, biomes: [.hillCrest, .moor]),
        WalkFinding(text: "the whole valley laid out and small", weight: weightCommon, biomes: [.hillCrest]),
        WalkFinding(text: "a trig point's bolt, brass, cold to the touch", weight: weightUncommon, biomes: [.hillCrest]),
        WalkFinding(text: "a worked flint, older than the field below", weight: weightRare, biomes: [.hillCrest, .fallowField]),
        // Marsh
        WalkFinding(text: "a dragonfly's cast skin gripping a reed", weight: weightCommon, biomes: [.marsh]),
        WalkFinding(text: "frogspawn in a ditch, a grey cloud of it", weight: weightCommon, biomes: [.marsh]),
        WalkFinding(text: "a snipe up in a zigzag, then gone", weight: weightUncommon, biomes: [.marsh]),
        // Fallow field
        WalkFinding(text: "hare droppings left on a molehill throne", weight: weightCommon, biomes: [.fallowField]),
        WalkFinding(text: "poppies where the plough missed", weight: weightCommon, biomes: [.fallowField]),
        WalkFinding(text: "a clay pigeon unbroken, orange in the green", weight: weightUncommon, biomes: [.fallowField])
    ]
}
