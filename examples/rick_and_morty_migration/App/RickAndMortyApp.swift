import CharacterUI
import CharactersFeature  // Apollo iOS 1.15.2
import EpisodesFeature    // Apollo iOS 2.4.0
import LocationsFeature   // Apollo iOS 1.15.2
import SwiftUI

@main
struct RickAndMortyApp: App {
  // Launch with `-tab episodes` (or locations) to open another tab, e.g. for screenshots.
  @State private var tab = UserDefaults.standard.string(forKey: "tab") ?? "characters"

  var body: some Scene {
    WindowGroup {
      TabView(selection: $tab) {
        Tab("Characters", systemImage: "person.3", value: "characters") {
          NavigationStack { CharactersScreen() }
        }
        Tab("Episodes", systemImage: "tv", value: "episodes") {
          NavigationStack { EpisodesScreen() }
        }
        Tab("Locations", systemImage: "globe", value: "locations") {
          NavigationStack { LocationsScreen() }
        }
      }
      // Every feature opens character details through CharacterUI; the screen itself
      // lives in the 1.15.2 Characters feature, so the 2.4.0 Episodes never imports it.
      .environment(\.characterDetail, CharacterDetailBuilder { AnyView(CharacterDetailScreen(id: $0)) })
    }
  }
}
