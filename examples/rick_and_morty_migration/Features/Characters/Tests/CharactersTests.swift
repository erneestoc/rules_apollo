// Apollo iOS 1.15.2: mocks and `Data.from(_:)` from that version's ApolloTestSupport.
import ApolloTestSupport
import CharactersFeature
import CharactersGraphQL
import RickAndMortyAPIMocks
import XCTest

@MainActor
final class CharactersTests: XCTestCase {
  func testPaginatesWithMockedPages() async {
    // 1.x: `from(_:)` is synchronous (it is async in 2.x).
    let page1 = CharactersQuery.Data.from(Mock<Query>(characters: Mock<Characters>(
      info: Mock<Info>(next: 2),
      results: [Mock<Character>(id: "1", name: "Rick Sanchez", species: "Human", status: "Alive")])))
    let page2 = CharactersQuery.Data.from(Mock<Query>(characters: Mock<Characters>(
      info: Mock<Info>(next: nil),
      results: [Mock<Character>(id: "2", name: "Morty Smith", species: "Human", status: "Alive")])))

    let model = CharactersModel { query in
      query.page == .some(1) ? page1 : page2
    }
    await model.refresh()
    XCTAssertEqual(model.characters.map(\.name), ["Rick Sanchez"])
    XCTAssertEqual(model.characters.first?.subtitle, "Alive · Human")
    XCTAssertEqual(model.nextPage, 2)

    await model.loadMore()
    XCTAssertEqual(model.characters.map(\.name), ["Rick Sanchez", "Morty Smith"])
    XCTAssertNil(model.nextPage)
  }

  func testDetailListsEpisodes() async {
    let character = Mock<Character>(id: "1", name: "Rick Sanchez")
    character.episode = [Mock<Episode>(episode: "S01E01", id: "1", name: "Pilot")]
    let data = CharacterDetailQuery.Data.from(Mock<Query>(character: character))

    let model = CharacterDetailModel(id: "1") { _ in data }
    await model.refresh()
    XCTAssertEqual(model.episodes, ["S01E01 · Pilot"])
  }
}
