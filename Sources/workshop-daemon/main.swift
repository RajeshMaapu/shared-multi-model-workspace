import Foundation
import WorkshopDaemonKit

func log(_ message: String) {
    FileHandle.standardError.write(Data("[workshop-daemon] \(message)\n".utf8))
}

let env = ProcessInfo.processInfo.environment

// A write to a closed pipe or socket (ACP client stdin after the child
// exited, an HTTP client that disconnected) must surface as an error at
// the call site — SIGPIPE's default action would kill the whole daemon.
signal(SIGPIPE, SIG_IGN)

// `workshop-daemon qualify ...` — one-shot capability run; never opens the
// live database (QualificationRunner builds its own temp home).
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "qualify" {
    guard let options = QualificationRunner.parse(CommandLine.arguments) else {
        FileHandle.standardError.write(
            Data(QualificationRunner.usage.utf8))
        exit(2)
    }
    let code = await QualificationRunner.run(options, env: env)
    exit(code)
}

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

let runtime: DaemonRuntime
do {
    runtime = try DaemonRuntime(home: home, runtimeDir: runtimeDir)
} catch {
    log("startup failed: \(error.localizedDescription)")
    exit(1)
}
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

// Park; the accept/reader threads do the work. dispatchMain() traps in an
// async main context, so sleep forever instead.
while true { try? await Task.sleep(for: .seconds(3600)) }
