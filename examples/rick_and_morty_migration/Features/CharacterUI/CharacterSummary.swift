import Foundation

/// A character as the UI shows it. Each feature maps its own runtime's generated
/// `CharacterCard` fragment to this, so screens on different Apollo versions share it.
public struct CharacterSummary: Hashable, Sendable {
  public let id: String?
  public let name: String
  public let status: String?
  public let species: String?
  public let imageURL: URL?

  public init(id: String?, name: String?, status: String?, species: String?, image: String?) {
    self.id = id
    self.name = name ?? "Unknown"
    self.status = status
    self.species = species
    self.imageURL = image.flatMap(URL.init(string:))
  }

  /// "Alive · Human", skipping missing parts.
  public var subtitle: String {
    [status, species].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
