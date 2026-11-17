import Foundation

/// What an injury's name says about where it is, to start its form from.
/// A suggestion only: the person confirms or changes both.
public struct InjurySuggestion: Equatable, Sendable {
    /// Nil when the name says nothing about the side: the form must ask, not assume left.
    public let side: Side?
    /// Tissue ids, the most likely first.
    public let tissues: [String]
}

extension Library {
    /// Words in an injury's name and the tissues they usually mean. A joint
    /// named by itself ("knee", "shoulder") maps to the tissue most often
    /// meant by it here, which the person can change.
    private static let injuryWords: [(words: [String], tissues: [String])] = [
        (["pec", "pecs", "pectoral", "pectoralis", "chest"], ["pec_major"]),
        (["rotator", "cuff", "supraspinatus", "infraspinatus", "impingement", "shoulder"], ["rotator_cuff"]),
        (["delt", "delts", "deltoid"], ["front_delt", "side_delt"]),
        (["tricep", "triceps"], ["triceps"]),
        (["bicep", "biceps", "brachialis"], ["biceps"]),
        (["forearm", "wrist", "grip", "elbow", "golfer", "golfers", "tennis"], ["forearm"]),
        (["lat", "lats", "latissimus"], ["lats"]),
        (["rhomboid", "rhomboids", "scapula", "scapular"], ["mid_back"]),
        (["trap", "traps", "trapezius", "neck"], ["upper_traps"]),
        (["lumbar", "erector", "erectors", "back", "spine", "spinal"], ["erectors"]),
        (["ab", "abs", "abdominal", "abdominals", "core"], ["abs"]),
        (["oblique", "obliques"], ["obliques"]),
        (["flexor", "psoas", "iliopsoas"], ["hip_flexors"]),
        (["glute", "glutes", "gluteus", "gluteal", "buttock", "piriformis"], ["glute_max"]),
        (["hip"], ["glute_med"]),
        (["groin", "adductor", "adductors"], ["adductors"]),
        (["quad", "quads", "quadriceps", "thigh"], ["quads"]),
        (["hamstring", "hamstrings"], ["hamstrings"]),
        (["patellar", "patella", "jumper", "jumpers", "knee"], ["patellar_tendon"]),
        (["calf", "calves", "gastrocnemius", "gastroc", "soleus"], ["calf"]),
        (["achilles", "heel"], ["achilles"]),
    ]

    public func suggestInjury(named label: String) -> InjurySuggestion {
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        let has = { (word: String) in words.contains(word) }
        var side: Side?
        let left = has("left") || has("l"), right = has("right") || has("r")
        if has("both") || has("bilateral") || (left && right) { side = .both }
        else if left { side = .left }
        else if right { side = .right }

        var found: [String] = []
        func add(_ ids: [String]) { for id in ids where tissue(id) != nil && !found.contains(id) { found.append(id) } }
        // More exact phrases first: they settle what a general word would guess at.
        if has("upper") && has("back") || has("mid") && has("back") { add(["mid_back"]) }
        if has("hip") && has("flexor") { add(["hip_flexors"]) }
        if has("glute") && (has("med") || has("medius")) || has("gluteus") && has("medius") { add(["glute_med"]) }
        if has("knee") && found.isEmpty { add(["patellar_tendon", "quads"]) }
        for entry in Library.injuryWords where entry.words.contains(where: has) {
            // A general word adds nothing once a more exact one has spoken for the area.
            if entry.tissues == ["erectors"], found.contains("mid_back"), !has("lumbar"), !has("lower"), !has("low") { continue }
            if entry.tissues == ["glute_med"], found.contains("hip_flexors") { continue }
            if entry.tissues == ["glute_max"], found.contains("glute_med") { continue }
            if entry.tissues == ["forearm"], has("elbow"), found.contains("triceps") || found.contains("biceps") { continue }
            add(entry.tissues)
        }
        return InjurySuggestion(side: side, tissues: found)
    }
}
