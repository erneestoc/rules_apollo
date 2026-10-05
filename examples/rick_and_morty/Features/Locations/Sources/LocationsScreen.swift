import CharactersFeature
import LocationsGraphQL
import Networking
import Observation
import SwiftUI

public typealias LocationSummary = LocationsQuery.Data.Locations.Result

extension LocationSummary {
  /// "Planet · Dimension C-137"
  public var subtitle: String {
    [type, dimension].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// The residents, as the CharacterCard fragment owned by the Characters feature.
  public var residentCards: [CharacterCard] {
    residents.compactMap { $0?.fragments.characterCard }
  }
}

@MainActor
@Observable
public final class LocationsModel {
  public typealias Loader = @Sendable (LocationsQuery) async throws -> LocationsQuery.Data

  public private(set) var locations: [LocationSummary] = []
  public private(set) var nextPage: Int? = 1
  public private(set) var error: String?

  private let load: Loader

  public init(load: @escaping Loader = { try await Network.fetch($0) }) {
    self.load = load
  }

  public func loadMore() async {
    guard let page = nextPage else { return }
    do {
      let data = try await load(LocationsQuery(page: .some(Int32(page))))
      locations += (data.locations?.results ?? []).compactMap { $0 }
      nextPage = data.locations?.info?.next
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

public struct LocationsScreen: View {
  @State private var model: LocationsModel

  @MainActor public init(model: LocationsModel? = nil) {
    _model = State(initialValue: model ?? LocationsModel())
  }

  public var body: some View {
    List {
      ForEach(Array(model.locations.enumerated()), id: \.offset) { _, location in
        NavigationLink {
          List(Array(location.residentCards.enumerated()), id: \.offset) { _, card in
            CharacterLink(card: card)
          }
          .navigationTitle(location.name ?? "")
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(location.name ?? "Unknown").font(.headline)
            Text("\(location.subtitle) · \(location.residents.count) \(location.residents.count == 1 ? "resident" : "residents")")
              .font(.subheadline).foregroundStyle(.secondary)
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
    .navigationTitle("Locations")
  }
}
