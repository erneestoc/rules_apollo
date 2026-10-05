import AnimalKingdomAPIMocks
import ApolloTestSupport
import PetsTestSupport
import XCTest

final class PetsMocksTests: XCTestCase {
  // Mutation is referenced only by Pets, so PetsTestSupport owns its mock. Its
  // fields name mocks owned by the base (Cat), which this module imports.
  func testFeatureMockUsesBaseMocks() {
    let mutation = Mock<Mutation>(adoptPet: Mock<Cat>(humanName: "Tom", species: "Felis catus"))
    let pet = mutation.adoptPet as? Mock<Cat>
    XCTAssertEqual(pet?.humanName, "Tom")
    XCTAssertEqual(pet?.species, "Felis catus")
  }
}
