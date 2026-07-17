import SwiftUI

/// v0 — proof it ducks. Start music in Spotify, come back here, tap the button:
/// the music should dim, the test clip should play, then the music comes back.
struct ContentView: View {
    private let ducker = AudioDucker()
    @State private var note: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Echo").font(.largeTitle.bold())
            Text("v0 — proof it ducks").foregroundStyle(.secondary)

            Button("Play test clip (duck music)") {
                guard let url = Bundle.main.url(forResource: "test", withExtension: "wav") else {
                    note = "Add a short test.wav to Resources/ (see README)."
                    return
                }
                note = nil
                ducker.play(url: url)
            }
            .buttonStyle(.borderedProminent)

            if let note {
                Text(note).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
