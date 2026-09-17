import XCTest
import Foundation
@testable import WorkshopAdapters

final class WriterSandboxTests: XCTestCase {
    func testDetachedChildCannotWriteControlPlaneOrOtherWriter() throws {
        let root = "/private/tmp/writer-sandbox-" + UUID().uuidString
        let work = root + "/writer-runs/one/workspace"
        let peer = root + "/writer-runs/two/workspace"
        let profile = root + "/profiles/clean-v2/devin"
        for path in [work, peer, profile, root + "/db", root + "/writer-snapshots/accepted"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let targets = [work + "/allowed", peer + "/denied", root + "/db/denied", root + "/writer-snapshots/accepted/denied"]
        let sb = root + "/policy.sb"
        try ProfileBuilder.writerSandboxProfile(workshopHome: root, worktree: work,
             profile: profile, token: root + "/profiles/devin/token", destination: sb)
        let script = """
        import os,sys,subprocess,json
        targets=json.loads(sys.argv[1])
        if len(sys.argv)==2:
            p=subprocess.run([sys.executable,'-c',sys.argv[0],sys.argv[1],'child'],start_new_session=True,capture_output=True,text=True)
            print(p.stdout,end='');sys.exit(p.returncode)
        result=[]
        for path in targets:
            try:
                with open(path,'w') as f:f.write('probe')
                result.append(True)
            except PermissionError:result.append(False)
        print(json.dumps(result))
        """
        // Pass source as argv[0] so the detached child runs the identical probe.
        let bootstrap = "import sys; source=sys.argv.pop(1); sys.argv[0]=source; exec(source)"
        let process = Process(); let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", sb, "/usr/bin/python3", "-c", bootstrap, script,
                             String(decoding: try JSONEncoder().encode(targets), as: UTF8.self)]
        process.environment = ["PATH":"/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE":"1"]
        process.standardOutput = out; process.standardError = FileHandle.standardError
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try JSONDecoder().decode([Bool].self, from: data), [true,false,false,false])
        for path in targets.dropFirst() { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
    }
}
