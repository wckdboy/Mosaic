import CoreGraphics
import Foundation
import FoundationModels

// The precise tier: Apple Intelligence's on-device model looks at a small thumbnail
// and returns structured tags for search. Nothing leaves the device. Where the model
// is unavailable (older devices, Apple Intelligence off, Simulator) Mosaic keeps the
// fast Vision labels and simply skips this tier.
enum MediaDescriber {
    static var isAvailable: Bool {
        guard #available(iOS 27.0, *) else { return false }
        let model = SystemLanguageModel(useCase: .contentTagging)
        return model.availability == .available && model.capabilities.contains(.vision)
    }

    struct Description: Sendable, Equatable {
        let caption: String
        let tags: [String]
    }

    @concurrent static func describe(_ image: CGImage) async -> Description? {
        guard #available(iOS 27.0, *) else { return nil }
        return await Tagger.describe(image)
    }

    // Lowercased, de-duplicated, length-limited phrases; empty and filler entries dropped.
    static func normalize(_ groups: [[String]]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for phrase in groups.joined() {
            let cleaned = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !cleaned.isEmpty, cleaned.count <= 40, !MediaSemantics.stopwords.contains(cleaned),
                seen.insert(cleaned).inserted
            else { continue }
            result.append(cleaned)
        }
        return Array(result.prefix(32))
    }
}

@available(iOS 27.0, *)
private enum Tagger {
    @Generable struct Tags {
        @Guide(description: "One short, literal sentence describing the image.")
        var caption: String
        @Guide(description: "Distinct visible objects, as short lowercase nouns.", .maximumCount(12))
        var objects: [String]
        @Guide(
            description:
                "People visible, described generically: woman, man, girl, boy, child, baby, couple, family, group, crowd. Empty when there are none.",
            .maximumCount(6))
        var people: [String]
        @Guide(description: "Activities or events shown, lowercase.", .maximumCount(5))
        var activities: [String]
        @Guide(description: "Setting or kind of place, lowercase.", .maximumCount(4))
        var setting: [String]
        @Guide(
            description: "Ideas, themes, and atmosphere the image evokes, e.g. travel, celebration, cozy, minimal.",
            .maximumCount(6))
        var ideas: [String]
    }

    static let instructions = """
        You label personal photos for private, on-device search. Be literal and specific, and \
        only list what is clearly visible. Use short lowercase words or phrases. Describe people \
        generically by appearance (for example woman, man, child, group); never guess names, \
        identities, ages, or health.
        """

    static func describe(_ image: CGImage) async -> MediaDescriber.Description? {
        // A fresh session per image keeps each request small and independent.
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging), instructions: instructions)
        do {
            let response = try await session.respond(
                generating: Tags.self, options: GenerationOptions(temperature: 0)
            ) {
                "Tag this photo for search."
                Attachment(image)
            }
            let tags = response.content
            let caption = tags.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            return MediaDescriber.Description(
                caption: String(caption.prefix(200)),
                tags: MediaDescriber.normalize([tags.people, tags.objects, tags.activities, tags.setting, tags.ideas]))
        } catch {
            // Guardrail refusals and unavailable assets fall back to the fast tier.
            return nil
        }
    }
}
