import SwiftUI

public struct CharacterRow: View {
  let character: CharacterSummary

  public init(_ character: CharacterSummary) {
    self.character = character
  }

  public var body: some View {
    HStack(spacing: 12) {
      AsyncImage(url: character.imageURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Color.secondary.opacity(0.2)
      }
      .frame(width: 48, height: 48)
      .clipShape(Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(character.name).font(.headline)
        Text(character.subtitle).font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }
}

/// Builds the character detail screen. The app installs the Characters feature's
/// screen here, so features on other runtimes can link to it without importing it.
public struct CharacterDetailBuilder: Sendable {
  public let build: @MainActor @Sendable (String) -> AnyView

  public init(_ build: @escaping @MainActor @Sendable (String) -> AnyView) {
    self.build = build
  }
}

private struct CharacterDetailKey: EnvironmentKey {
  static let defaultValue = CharacterDetailBuilder { _ in AnyView(EmptyView()) }
}

extension EnvironmentValues {
  public var characterDetail: CharacterDetailBuilder {
    get { self[CharacterDetailKey.self] }
    set { self[CharacterDetailKey.self] = newValue }
  }
}

/// A row that opens the character's detail screen.
public struct CharacterLink: View {
  let character: CharacterSummary
  @Environment(\.characterDetail) private var detail

  public init(_ character: CharacterSummary) {
    self.character = character
  }

  public var body: some View {
    if let id = character.id {
      NavigationLink {
        detail.build(id)
      } label: {
        CharacterRow(character)
      }
    } else {
      CharacterRow(character)
    }
  }
}
