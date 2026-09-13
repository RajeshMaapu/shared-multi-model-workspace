import Foundation
import WorkshopDaemonKit

func log(_ message: String) {
    FileHandle.standardError.write(Data("[workshop-daemon] \(message)\n".utf8))
}

let env = ProcessInfo.processInfo.environment
let home = env["WORKSHOP_HOME"]
    ?? NSHomeDirectory() + "/Library/Application Support/Workshop"
let runtimeDir = DaemonRuntime.defaultRuntimeDir()

// Exclusive single-instance lock.
let lockFD = open(runtimeDir + "/service.lock", O_RDWR | O_CREAT, 0o600)
if lockFD >= 0 {
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        print("workshop-daemon already running")
        exit(0)
    }
}

let runtime = try DaemonRuntime(home: home, runtimeDir: runtimeDir)
try await runtime.start()

let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM,
                                             queue: DispatchQueue.global())
signal(SIGTERM, SIG_IGN)
sigSrc.setEventHandler {
    log("SIGTERM received, shutting down")
    Task.detached {
        await runtime.shutdown()
        exit(0)
    }
}
sigSrc.resume()

// Park the main thread; the accept/reader threads do the work.
dispatchMain()
