import Foundation
import TheiaRemote

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

exit(RemoteHelper.serve(input: .standardInput, output: .standardOutput))
