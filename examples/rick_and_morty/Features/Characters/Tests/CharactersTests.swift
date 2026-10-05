import ApolloTestSupport
import CharactersFeature
import CharactersGraphQL
import RickAndMortyAPIMocks
import XCTest

@MainActor
final class CharactersTests: XCTestCase {
  private func rick() -> Mock<Character> {
    Mock<Character>(id: "1", image: "https://example.com/1.jpeg", name: "Rick Sanchez", species: "Human", status: "Alive")
  }

  func testPaginatesWithMockedPages() async {
    let page1 = await CharactersQuery.Data.from(
      Mock<Query>(characters: Mock<Characters>(info: Mock<Info>(next: 2), results: [rick()])))
    let page2 = await CharactersQuery.Data.from(
      Mock<Query>(characters: Mock<Characters>(info: Mock<Info>(next: nil), results: [
        Mock<Character>(id: "2", name: "Morty Smith", species: "Human", status: "Alive"),
      ])))

    let model = CharactersModel { query in
      query.page == .some(1) ? page1 : page2
    }
    await model.refresh()
    XCTAssertEqual(model.characters.map(\.name), ["Rick Sanchez"])
    XCTAssertEqual(model.nextPage, 2)

    await model.loadMore()
    XCTAssertEqual(model.characters.map(\.name), ["Rick Sanchez", "Morty Smith"])
    XCTAssertNil(model.nextPage)
  }

  func testSearchIsSentAsNameFilter() async {
    let empty = await CharactersQuery.Data.from(Mock<Query>(characters: Mock<Characters>(results: [])))
    let seen = Box<CharactersQuery?>(nil)
    let model = CharactersModel { query in
      seen.value = query
      return empty
    }
    model.search = "Rick"
    await model.refresh()
    XCTAssertEqual(seen.value?.name, .some("Rick"))
  }

  func testDetailListsEpisodes() async {
    let character = rick()
    character.episode = [Mock<Episode>(episode: "S01E01", id: "1", name: "Pilot")]
    let data = await CharacterDetailQuery.Data.from(Mock<Query>(character: character))

    let model = CharacterDetailModel(id: "1") { _ in data }
    await model.refresh()
    XCTAssertEqual(model.character?.name, "Rick Sanchez")
    XCTAssertEqual(model.episodes, ["S01E01 · Pilot"])
  }

  func testCardSubtitleSkipsMissingParts() async {
    let data = await CharactersQuery.Data.from(Mock<Query>(characters: Mock<Characters>(results: [
      Mock<Character>(name: "Mr. Poopybutthole", species: "Unknown", status: nil),
    ])))
    XCTAssertEqual(data.characters?.results?.first??.fragments.characterCard.subtitle, "Unknown")
  }
}

/// Lets a @Sendable loader record what it was called with.
final class Box<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}
