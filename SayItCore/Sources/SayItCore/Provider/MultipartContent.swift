import Foundation

/// Polymorphic encoding of a message's content as "a string OR an array of content blocks", shared by the OpenAI / Anthropic protocols:
/// - `.text(s)`: encoded as a single string value (byte-for-byte identical to the old image-free behavior).
/// - `.parts(text:images:)`: encoded as an array `[text block, image blocks...]`, where the text block is fixed to `{"type":"text","text":...}`,
///   and the image blocks come from each Provider's own leaf (OpenAI's image_url part / Anthropic's base64 source part).
///
/// This only wraps the "string OR [text-part, image-parts...]" skeleton; the concrete leaf type is decided by the generic parameter `ImagePart`,
/// so the bytes encoded by both Providers stay exactly identical to their respective old implementations.
enum MultipartContent<ImagePart: Encodable>: Encodable {
    case text(String)
    case parts(text: String, images: [ImagePart])

    /// Text block: both protocols use `{"type":"text","text":...}`, so it can be shared.
    private struct TextPart: Encodable { let type = "text"; let text: String }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case let .parts(text, images):
            var c = encoder.unkeyedContainer()
            try c.encode(TextPart(text: text))
            for img in images { try c.encode(img) }
        }
    }
}
