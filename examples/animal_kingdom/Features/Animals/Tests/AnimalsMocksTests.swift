import AnimalKingdomAPIMocks
import AnimalsGraphQL
import ApolloTestSupport
import PetsTestSupport
import XCTest

final class AnimalsMocksTests: XCTestCase {
  // Mocks build the generated operation data the feature's code consumes.
  func testQueryDataFromMocks() async {
    let dog = Mock<Dog>(
      height: Mock<Height>(feet: 2, meters: 1),
      id: "1",
      skinCovering: .case(.fur),
      species: "Canis familiaris"
    )
    let data = await DogQuery.Data.from(Mock<Query>(allAnimals: [dog]))

    XCTAssertEqual(data.allAnimals.count, 1)
    XCTAssertEqual(data.allAnimals[0].id, "1")
    XCTAssertEqual(data.allAnimals[0].asDog?.species, "Canis familiaris")
  }

  // Feature mock modules hold disjoint types, so a test can link several:
  // Mutation comes from PetsTestSupport, Dog from the base.
  func testMocksFromSeveralModulesLinkTogether() {
    let mutation = Mock<Mutation>(adoptPet: Mock<Dog>(species: "Canis familiaris"))
    XCTAssertEqual((mutation.adoptPet as? Mock<Dog>)?.species, "Canis familiaris")
  }
}
