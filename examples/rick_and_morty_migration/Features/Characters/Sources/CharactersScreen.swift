// On the "current" runtime: Apollo iOS 1.15.2.
import CharacterUI
import CharactersGraphQL
import Networking
import Observation
import SwiftUI

extension CharacterCard {
  /// The version-neutral model the shared UI takes.
  public var summary: CharacterSummary {
    CharacterSummary(id: id, name: name, status: status, species: species, image: image)
  }
}

@MainActor
@Observable
public final class CharactersModel {
  public typealias Loader = (CharactersQuery) async throws -> CharactersQuery.Data

  public private(set) var characters: [CharacterSummary] = []
  public private(set) var nextPage: Int?
  public private(set) var error: String?
  public var search = ""

  private let load: Loader

  public init(load: @escaping Loader = { try await Network.fetch($0) }) {
    self.load = load
  }

  public func refresh() async {
    characters = []
    nextPage = nil
    await fetch(page: 1)
  }

  public func loadMore() async {
    guard let nextPage else { return }
    await fetch(page: nextPage)
  }

  private func fetch(page: Int) async {
    let name = search.isEmpty ? GraphQLNullable<String>.none : .some(search)
    do {
      // Apollo iOS 1.x: `Int` variables (2.x generates `Int32`).
      let data = try await load(CharactersQuery(page: .some(page), name: name))
      characters += (data.characters?.results ?? []).compactMap { $0?.fragments.characterCard.summary }
      nextPage = data.characters?.info?.next
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

public struct CharactersScreen: View {
  @State private var model: CharactersModel

  @MainActor public init(model: CharactersModel? = nil) {
    _model = State(initialValue: model ?? CharactersModel())
  }

  public var body: some View {
    List {
      ForEach(Array(model.characters.enumerated()), id: \.offset) { _, character in
        CharacterLink(character)
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
    .navigationTitle("Characters · Apollo 1.15")
    .searchable(text: $model.search)
    .onSubmit(of: .search) { Task { await model.refresh() } }
    .task { if model.characters.isEmpty { await model.refresh() } }
  }
}
