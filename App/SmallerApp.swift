import SwiftUI
import SmallerKit

/// Entry point only. The screens land in phase 2, once the engine numbers are
/// signed off — there is deliberately no UI here yet.
@main
struct SmallerApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Smaller")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
        }
    }
}
