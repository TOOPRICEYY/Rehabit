import Foundation

/// What an injury's name says about where it is, to start its form from.
/// A suggestion only: the person confirms or changes both. A wrong tissue is
/// worse than none, so a name that only places the injury near a joint
/// ("behind the knee") suggests the muscle named, and a name this cannot
/// read suggests nothing.
public struct InjurySuggestion: Equatable, Sendable {
    /// Nil when the name says nothing about the side: the form must ask, not assume left.
    public let side: Side?
    /// Tissue ids, the most likely first.
    public let tissues: [String]
}

extension Library {
    /// Words that name a tissue outright.
    private static let tissueWords: [(words: [String], tissues: [String])] = [
        (["pec", "pecs", "pectoral", "pectoralis", "chest"], ["pec_major"]),
        (["rotator", "cuff", "supraspinatus", "infraspinatus", "impingement"], ["rotator_cuff"]),
        (["delt", "delts", "deltoid"], ["front_delt", "side_delt"]),
        (["tricep", "triceps"], ["triceps"]),
        (["bicep", "biceps", "brachialis"], ["biceps"]),
        (["forearm", "wrist", "grip", "golfer", "golfers"], ["forearm"]),
        (["lat", "lats", "latissimus"], ["lats"]),
        (["rhomboid", "rhomboids", "scapula", "scapular"], ["mid_back"]),
        (["trap", "traps", "trapezius", "neck"], ["upper_traps"]),
        (["lumbar", "erector", "erectors", "spine", "spinal", "disc", "sciatica"], ["erectors"]),
        (["ab", "abs", "abdominal", "abdominals", "core"], ["abs"]),
        (["oblique", "obliques"], ["obliques"]),
        (["flexor", "flexors", "psoas", "iliopsoas"], ["hip_flexors"]),
        (["glute", "glutes", "gluteus", "gluteal", "buttock", "piriformis"], ["glute_max"]),
        (["groin", "adductor", "adductors"], ["adductors"]),
        (["quad", "quads", "quadriceps"], ["quads"]),
        (["hamstring", "hamstrings"], ["hamstrings"]),
        (["patellar", "patella", "jumper", "jumpers"], ["patellar_tendon"]),
        (["calf", "calves", "gastrocnemius", "gastroc", "soleus"], ["calf"]),
        (["achilles"], ["achilles"]),
    ]

    /// A joint or region named with nothing more exact: the tissue most often
    /// meant by it here. Used only when no tissue word was found.
    private static let regionWords: [(words: [String], tissues: [String])] = [
        (["shoulder", "shoulders"], ["rotator_cuff"]),
        (["elbow", "elbows"], ["forearm"]),
        (["back"], ["erectors"]),
        (["hip", "hips"], ["glute_med"]),
        (["thigh", "thighs"], ["quads"]),
        (["knee", "knees"], ["patellar_tendon", "quads"]),
    ]

    public func suggestInjury(named label: String) -> InjurySuggestion {
        // Letters and digits stay together: "L4" is a spinal level, not "left".
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let has = { (word: String) in words.contains(word) }
        func follows(_ first: String, _ second: String, within gap: Int = 2) -> Bool {
            for (i, word) in words.enumerated() where word == first {
                if words[(i + 1)...].prefix(gap).contains(second) { return true }
            }
            return false
        }
        var side: Side?
        let left = has("left") || has("l"), right = has("right") || has("r")
        if has("both") || has("bilateral") || (left && right) { side = .both }
        else if left { side = .left }
        else if right { side = .right }

        var found: [String] = []
        func add(_ ids: [String]) { for id in ids where tissue(id) != nil && !found.contains(id) { found.append(id) } }
        // "Back of", "front of", "behind", "below" place the injury; they do not name the spine or the joint.
        let backOf = follows("back", "of", within: 1), frontOf = follows("front", "of", within: 1)
        // Phrases first: they settle what a single word would guess at.
        if has("upper") && has("back") || has("mid") && has("back") { add(["mid_back"]) }
        if (has("lower") || has("low")) && has("back") { add(["erectors"]) }
        if has("hip") && (has("flexor") || has("flexors")) || frontOf && has("hip") { add(["hip_flexors"]) }
        if (has("glute") || has("gluteus")) && (has("med") || has("medius") || has("min") || has("minimus")) { add(["glute_med"]) }
        // Gluteal tendinopathy is the gluteus medius and minimus tendons, not the gluteus maximus.
        if has("gluteal") && (has("tendinopathy") || has("tendinitis") || has("tendinosis") || has("tendon")) { add(["glute_med"]) }
        if backOf && (has("thigh") || has("thighs")) { add(["hamstrings"]) }
        // Tennis elbow is the wrist extensors, which have no tissue here: nothing is better than the flexors.
        let tennis = has("tennis") && (has("elbow") || has("elbows"))
        for entry in Library.tissueWords where entry.words.contains(where: has) {
            if entry.tissues == ["glute_max"], found.contains("glute_med") { continue }
            if entry.tissues == ["hip_flexors"], found.contains("forearm") || has("wrist") || has("forearm") { continue }
            add(entry.tissues)
        }
        // A bare joint or region speaks only when nothing more exact did, and not as a landmark.
        if found.isEmpty, !tennis {
            for entry in Library.regionWords where entry.words.contains(where: has) {
                if entry.words.contains("back"), backOf { continue }
                if backOf || frontOf || has("behind") || has("below") || has("above") || has("under") {
                    // "Back of knee", "front of hip": a place this cannot turn into a tissue.
                    if !(entry.words.contains("back")) { continue }
                }
                add(entry.tissues)
            }
        }
        return InjurySuggestion(side: side, tissues: found)
    }
}
