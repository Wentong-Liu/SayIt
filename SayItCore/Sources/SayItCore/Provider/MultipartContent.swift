import Foundation

/// 一条 message 的 content 的「字符串 或 内容块数组」多态编码，OpenAI / Anthropic 协议共用此形状：
/// - `.text(s)`：编为单值字符串（与无图旧行为逐字节一致）。
/// - `.parts(text:images:)`：编为数组 `[文本块, 图片块...]`，文本块固定为 `{"type":"text","text":...}`，
///   图片块由各 Provider 提供自己的 leaf（OpenAI 的 image_url part / Anthropic 的 base64 source part）。
///
/// 仅封装这层「string OR [text-part, image-parts...]」骨架；具体 leaf 类型由泛型参数 `ImagePart` 决定，
/// 故两个 Provider 编码出的字节与各自旧实现完全一致。
enum MultipartContent<ImagePart: Encodable>: Encodable {
    case text(String)
    case parts(text: String, images: [ImagePart])

    /// 文本块：两协议均为 `{"type":"text","text":...}`，故可共用。
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
