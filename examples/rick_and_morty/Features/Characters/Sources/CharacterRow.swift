import CharactersGraphQL
import SwiftUI

extension CharacterCard {
  /// "Alive · Human", skipping missing parts.
  public var subtitle: String {
    [status, species].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

/// One character, rendered from the `CharacterCard` fragment. Episodes and
/// Locations spread the same fragment and reuse this row.
public struct CharacterRow: View {
  let card: CharacterCard

  public init(card: CharacterCard) {
    self.card = card
  }

  public var body: some View {
    HStack(spacing: 12) {
      AsyncImage(url: card.image.flatMap(URL.init(string:))) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Color.secondary.opacity(0.2)
      }
      .frame(width: 48, height: 48)
      .clipShape(Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(card.name ?? "Unknown").font(.headline)
        Text(card.subtitle).font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }
}

/// Opens a character's detail screen. Other features link here too.
public struct CharacterLink: View {
  let card: CharacterCard

  public init(card: CharacterCard) {
    self.card = card
  }

  public var body: some View {
    if let id = card.id {
      NavigationLink {
        CharacterDetailScreen(id: id)
      } label: {
        CharacterRow(card: card)
      }
    } else {
      CharacterRow(card: card)
    }
  }
}
