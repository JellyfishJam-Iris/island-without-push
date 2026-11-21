import Foundation

/// What one poll answer carries. Every key may be missing, and a key that does not decode is dropped on
/// its own, so a server-side mistake in one field never costs the others.
struct PollResponse: Decodable {
    let island: IslandInfo?
    let messages: [Message]?

    private enum CodingKeys: String, CodingKey { case island, messages }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        island = try? values.decodeIfPresent(IslandInfo.self, forKey: .island)
        messages = (try? values.decodeIfPresent([Lenient<Message>].self, forKey: .messages))?.compactMap(\.value)
    }
}

/// One element of a list that is skipped (nil) when it does not decode.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// The sprite's state and the island's line, decided on the server. `hide` ends the activity.
struct IslandInfo: Decodable, Equatable {
    let state: String?
    let line: String?
    let hide: Bool?
}

/// A message the server wants the phone to be told about. `id` is what de-duplicates it.
struct Message: Decodable, Equatable {
    let id: String
    let text: String
    let title: String?
    /// Where a tap should land (2026/11/22): the lake's room, the message to stop at, or a page such as
    /// "diary". Each is optional and dropped on its own if it does not decode.
    let room: Int?
    let msg: Int?
    let page: String?

    private enum CodingKeys: String, CodingKey { case id, text, title, room, msg, page }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        title = try? values.decodeIfPresent(String.self, forKey: .title)
        room = try? values.decodeIfPresent(Int.self, forKey: .room)
        msg = try? values.decodeIfPresent(Int.self, forKey: .msg)
        page = try? values.decodeIfPresent(String.self, forKey: .page)
    }
}
