import Foundation
import Darwin

/// One-shot, non-interactive batch operation. Built inside the application bundle
/// so Bundle.main can find the same engine and models as the graphical app.
@main
struct MemoBridgeCLI {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print("Usage: memobridge\nScan Voice Memos, transcribe pending recordings, and exit.")
            exit(0)
        }
        guard arguments.isEmpty else {
            fputs("Usage: memobridge [--help]\n", stderr)
            exit(2)
        }
        let result = await BatchProcessor.run(store: MemoStore())
        exit(result)
    }

}
