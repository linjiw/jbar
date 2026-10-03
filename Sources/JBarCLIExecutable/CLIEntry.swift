import Darwin
import JBarCLI

@main
struct JBarCLIExecutable {
    static func main() async {
        // Convert a closed agent/shell output pipe into the documented I/O exit code.
        signal(SIGPIPE, SIG_IGN)
        exit(await runJBarCLI(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}
