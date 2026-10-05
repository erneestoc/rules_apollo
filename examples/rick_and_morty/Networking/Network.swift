import Apollo
import ApolloAPI
import Foundation

/// The app's single Apollo client, talking to the public Rick and Morty API.
public enum Network {
  public static let client = ApolloClient(url: URL(string: "https://rickandmortyapi.com/graphql")!)

  /// Fetches a query and returns its data, or throws the first GraphQL error.
  public static func fetch<Query: GraphQLQuery>(_ query: Query) async throws -> Query.Data
  where Query.ResponseFormat == SingleResponseFormat {
    let response = try await client.fetch(query: query, cachePolicy: .cacheFirst)
    if let error = response.errors?.first { throw error }
    guard let data = response.data else { throw NetworkError.noData }
    return data
  }
}

public enum NetworkError: Error {
  case noData
}
