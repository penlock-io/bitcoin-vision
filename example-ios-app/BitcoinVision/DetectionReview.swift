import Foundation

extension DetectionSource {
    /** Geometry-only sources stay separate from read words and their alternatives. */
    var unread: Bool {
        recoveredWord == nil && !parts.contains { $0.wordIndex != nil } && union?.wordIndex == nil
    }

    /** Presentation of a native decision, never another app-side keep policy. */
    var reviewDescription: String {
        switch decision {
        case "owned_descender", "duplicate": return "Small ink belonging to a nearby word"
        case "detached_ending": return "Detached word ending"
        case "ambiguous_owner", "other_observation", "owner_unavailable", "no_owner":
            return "Small ink with no confirmed owner"
        default: return "Region that could not be read"
        }
    }
}
