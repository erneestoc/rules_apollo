// Apollo iOS 2.4.0: same imports as the 1.15.2 tests; they resolve to the _v2 modules.
import ApolloTestSupport
import EpisodesFeature
import EpisodesGraphQL
import RickAndMortyAPIMocks
import XCTest

@MainActor
final class EpisodesTests: XCTestCase {
  func testEpisodesMapTheirCastToSummaries() async {
    // 2.x: `from(_:)` is async.
    let data = await EpisodesQuery.Data.from(Mock<Query>(episodes: Mock<Episodes>(
      info: Mock<Info>(next: nil),
      results: [
        Mock<Episode>(
          air_date: "December 2, 2013",
          characters: [
            Mock<Character>(id: "1", name: "Rick Sanchez", species: "Human", status: "Alive"),
            Mock<Character>(id: "2", name: "Morty Smith", species: "Human", status: "Alive"),
          ],
          episode: "S01E01",
          id: "1",
          name: "Pilot"
        ),
      ]
    )))

    let model = EpisodesModel { _ in data }
    await model.loadMore()

    let pilot = try! XCTUnwrap(model.episodes.first)
    XCTAssertEqual(pilot.subtitle, "S01E01 · December 2, 2013")
    // The 2.4.0 CharacterCard, mapped to the version-neutral CharacterSummary.
    XCTAssertEqual(pilot.cast.map(\.name), ["Rick Sanchez", "Morty Smith"])
    XCTAssertEqual(pilot.cast.first?.subtitle, "Alive · Human")
    XCTAssertNil(model.nextPage)
  }
}
