@_spi(Internal) @_spi(Execution) import ApolloAPI

// A hand-written custom scalar. `custom_scalars` drops the CLI's default
// `typealias CustomDate = String`, which would otherwise be a redeclaration.
public struct CustomDate: CustomScalarType, Hashable {
  public let value: String

  public init(_jsonValue value: JSONValue) throws {
    guard let string = value as? String else {
      throw JSONDecodingError.couldNotConvert(value: value, to: String.self)
    }
    self.value = string
  }

  public var _jsonValue: JSONValue { value }
}
