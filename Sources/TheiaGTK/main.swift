import Glibc

GTKDisplayPolicy.configure()
let arguments = Array(CommandLine.arguments.dropFirst())
let status = MainActor.assumeIsolated {
    GTKApplicationController(paths: arguments).run()
}
exit(status)
