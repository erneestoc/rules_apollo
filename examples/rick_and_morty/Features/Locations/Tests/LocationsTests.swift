import ApolloTestSupport
import LocationsFeature
import LocationsGraphQL
import RickAndMortyAPIMocks
import XCTest

@MainActor
final class LocationsTests: XCTestCase {
  func testLocationsCarryTheirResidents() async {
    let data = await LocationsQuery.Data.from(Mock<Query>(locations: Mock<Locations>(
      info: Mock<Info>(next: 2),
      results: [
        Mock<Location>(
          dimension: "Dimension C-137",
          id: "1",
          name: "Earth (C-137)",
          residents: [Mock<Character>(id: "1", name: "Rick Sanchez", species: "Human", status: "Alive")],
          type: "Planet"
        ),
      ]
    )))

    let model = LocationsModel { _ in data }
    await model.loadMore()

    let earth = try! XCTUnwrap(model.locations.first)
    XCTAssertEqual(earth.subtitle, "Planet · Dimension C-137")
    XCTAssertEqual(earth.residentCards.map(\.name), ["Rick Sanchez"])
    XCTAssertEqual(model.nextPage, 2)
  }
}
