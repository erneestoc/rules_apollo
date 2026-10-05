import CharactersGraphQL
import Networking
import Observation
import SwiftUI

@MainActor
@Observable
public final class CharactersModel {
  public typealias Loader = @Sendable (CharactersQuery) async throws -> CharactersQuery.Data

  public private(set) var characters: [CharacterCard] = []
  public private(set) var nextPage: Int?
  public private(set) var error: String?
  public var search = ""

  private let load: Loader

  public init(load: @escaping Loader = { try await Network.fetch($0) }) {
    self.load = load
  }

  /// Loads the first page for the current search.
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
      let data = try await load(CharactersQuery(page: .some(Int32(page)), name: name))
      let results = data.characters?.results ?? []
      characters += results.compactMap { $0?.fragments.characterCard }
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
      ForEach(Array(model.characters.enumerated()), id: \.offset) { _, card in
        CharacterLink(card: card)
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
    .navigationTitle("Characters")
    .searchable(text: $model.search)
    .onSubmit(of: .search) { Task { await model.refresh() } }
    .task { if model.characters.isEmpty { await model.refresh() } }
  }
}
