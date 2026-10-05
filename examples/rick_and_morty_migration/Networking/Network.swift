import Apollo
import ApolloAPI
import Foundation

/// The app's Apollo client for the public Rick and Morty API. One per runtime: each
/// runtime has its own client and its own normalized cache.
public enum Network {
  public static let client = ApolloClient(url: URL(string: "https://rickandmortyapi.com/graphql")!)

  #if APOLLO_IOS_2
  /// Fetches a query and returns its data, or throws the first GraphQL error.
  public static func fetch<Query: GraphQLQuery>(_ query: Query) async throws -> Query.Data
  where Query.ResponseFormat == SingleResponseFormat {
    let response = try await client.fetch(query: query, cachePolicy: .cacheFirst)
    if let error = response.errors?.first { throw error }
    guard let data = response.data else { throw NetworkError.noData }
    return data
  }
  #else
  /// Apollo iOS 1.x is callback based; expose the same async API as 2.x.
  public static func fetch<Query: GraphQLQuery>(_ query: Query) async throws -> Query.Data {
    try await withCheckedThrowingContinuation { continuation in
      client.fetch(query: query, cachePolicy: .returnCacheDataElseFetch) { result in
        switch result {
        case .success(let response):
          if let error = response.errors?.first {
            continuation.resume(throwing: error)
          } else if let data = response.data {
            continuation.resume(returning: data)
          } else {
            continuation.resume(throwing: NetworkError.noData)
          }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }
  #endif
}

public enum NetworkError: Error {
  case noData
}
