import CharactersFeature
import EpisodesFeature
import LocationsFeature
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
    }
  }
}
