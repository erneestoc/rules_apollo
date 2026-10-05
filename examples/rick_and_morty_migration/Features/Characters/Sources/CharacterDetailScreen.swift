import CharacterUI
import CharactersGraphQL
import Networking
import Observation
import SwiftUI

@MainActor
@Observable
public final class CharacterDetailModel {
  public typealias Loader = (CharacterDetailQuery) async throws -> CharacterDetailQuery.Data

  public private(set) var character: CharacterDetailQuery.Data.Character?
  public private(set) var error: String?

  private let id: String
  private let load: Loader

  public init(id: String, load: @escaping Loader = { try await Network.fetch($0) }) {
    self.id = id
    self.load = load
  }

  public func refresh() async {
    do {
      character = try await load(CharacterDetailQuery(id: id)).character
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// "S01E01 · Pilot" for each episode the character appears in.
  public var episodes: [String] {
    (character?.episode ?? []).compactMap { episode in
      guard let episode else { return nil }
      return [episode.episode, episode.name].compactMap { $0 }.joined(separator: " · ")
    }
  }
}

/// The detail screen. Other features reach it through CharacterUI's `characterDetail`
/// environment value, which the app sets, so they don't import this 1.15.2 module.
public struct CharacterDetailScreen: View {
  @State private var model: CharacterDetailModel

  @MainActor public init(id: String) {
    _model = State(initialValue: CharacterDetailModel(id: id))
  }

  public var body: some View {
    List {
      if let character = model.character {
        Section {
          CharacterRow(character.fragments.characterCard.summary)
        }
        Section("Details") {
          LabeledContent("Gender", value: character.gender ?? "Unknown")
          LabeledContent("Origin", value: character.origin?.name ?? "Unknown")
          LabeledContent("Last seen", value: character.location?.name ?? "Unknown")
        }
        Section("Episodes") {
          ForEach(model.episodes, id: \.self) { Text($0) }
        }
      } else if let error = model.error {
        Text(error).foregroundStyle(.red)
      } else {
        ProgressView()
      }
    }
    .navigationTitle(model.character?.name ?? "")
    .task { await model.refresh() }
  }
}
