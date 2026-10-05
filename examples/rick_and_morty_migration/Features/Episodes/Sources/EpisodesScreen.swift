// On the "next" runtime: Apollo iOS 2.4.0. Modules that exist on both runtimes are
// imported by their 2.4.0 names (Networking_v2); Apollo iOS itself is aliased, so any
// `import ApolloAPI` here would reach ApolloAPI_v2.
import CharacterUI
import EpisodesGraphQL
import Networking_v2
import Observation
import SwiftUI

public typealias EpisodeSummary = EpisodesQuery.Data.Episodes.Result

extension EpisodeSummary {
  /// "S01E01 · December 2, 2013"
  public var subtitle: String {
    [episode, air_date].compactMap { $0 }.joined(separator: " · ")
  }

  /// The cast. CharacterCard here is the 2.4.0 variant of the Characters fragment, so it
  /// is mapped to the version-neutral CharacterSummary for the shared row.
  public var cast: [CharacterSummary] {
    characters.compactMap { character in
      character.map { card in
        let card = card.fragments.characterCard
        return CharacterSummary(id: card.id, name: card.name, status: card.status, species: card.species, image: card.image)
      }
    }
  }
}

@MainActor
@Observable
public final class EpisodesModel {
  public typealias Loader = @Sendable (EpisodesQuery) async throws -> EpisodesQuery.Data

  public private(set) var episodes: [EpisodeSummary] = []
  public private(set) var nextPage: Int? = 1
  public private(set) var error: String?

  private let load: Loader

  public init(load: @escaping Loader = { try await Network.fetch($0) }) {
    self.load = load
  }

  public func loadMore() async {
    guard let page = nextPage else { return }
    do {
      // Apollo iOS 2.x: `Int32` variables.
      let data = try await load(EpisodesQuery(page: .some(Int32(page))))
      episodes += (data.episodes?.results ?? []).compactMap { $0 }
      nextPage = data.episodes?.info?.next
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

public struct EpisodesScreen: View {
  @State private var model: EpisodesModel

  @MainActor public init(model: EpisodesModel? = nil) {
    _model = State(initialValue: model ?? EpisodesModel())
  }

  public var body: some View {
    List {
      ForEach(Array(model.episodes.enumerated()), id: \.offset) { _, episode in
        NavigationLink {
          List(Array(episode.cast.enumerated()), id: \.offset) { _, character in
            CharacterLink(character)
          }
          .navigationTitle(episode.name ?? "")
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(episode.name ?? "Unknown").font(.headline)
            Text(episode.subtitle).font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }
      if model.nextPage != nil {
        ProgressView()
          .frame(maxWidth: .infinity)
          .task { await model.loadMore() }
      }
      if let error = model.error {
        Text(error).foregroundStyle(.red)
      }
    }
    .navigationTitle("Episodes · Apollo 2.4")
  }
}
