import XCTest
import Foundation
@testable import WorkshopAdapters

final class WriterSandboxTests: XCTestCase {
    func testWriterCanReadOnlyStableBridgeCopy() throws {
        let root = "/private/tmp/writer-bridge-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let work = root + "/writer-runs/one/workspace"
        let profile = root + "/profiles/clean-v2/devin"
        let bridge = root + "/bin/workshop-mcp"
        let control = root + "/db/private"
        for path in [work, profile, root + "/bin", root + "/db"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try Data("bridge".utf8).write(to: URL(fileURLWithPath: bridge))
        try Data("private".utf8).write(to: URL(fileURLWithPath: control))
        let policy = root + "/policy.sb"
        try ProfileBuilder.writerSandboxProfile(workshopHome: root, worktree: work,
             profile: profile, token: root + "/writer-runs/one/token", destination: policy)
        let script = """
        import sys,json
        result=[]
        for path in sys.argv[1:]:
            try: open(path).read(); result.append(True)
            except PermissionError: result.append(False)
        print(json.dumps(result))
        """
        let process = Process(); let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", policy, "/usr/bin/python3", "-c", script, bridge, control]
        process.environment = ["PATH":"/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE":"1"]
        process.standardOutput = out; process.standardError = FileHandle.standardError
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try JSONDecoder().decode([Bool].self, from: data), [true, false])
    }

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

    /// fs.watch()/vnode lookup stats every ancestor of the watched path, so the
    /// profile must grant file-read-metadata on the ancestors of the allowed
    /// subpaths — without exposing metadata for unrelated Workshop state.
    func testAncestorMetadataGrantUnblocksWatchWithoutLeakingSiblings() throws {
        let root = "/private/tmp/writer-sandbox-" + UUID().uuidString
        let work = root + "/writer-runs/one/workspace"
        let profile = root + "/profiles/clean-v2/kimi"
        for path in [work, profile, root + "/db"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let sb = root + "/policy.sb"
        try ProfileBuilder.writerSandboxProfile(workshopHome: root, worktree: work,
             profile: profile, token: root + "/profiles/kimi/token", destination: sb,
             engineer: .kimi)
        let text = try String(contentsOfFile: sb)
        XCTAssertTrue(text.contains("(subpath \"\(profile)\")"))
        for ancestor in [root, root + "/writer-runs", root + "/profiles", root + "/profiles/clean-v2"] {
            XCTAssertTrue(text.contains("(literal \"\(ancestor)\")"), ancestor)
        }
        let script = """
        import os,sys,json
        result=[]
        for path in json.loads(sys.argv[1]):
            try: os.stat(path); result.append(True)
            except OSError: result.append(False)
        print(json.dumps(result))
        """
        let probes = [work, profile, root + "/writer-runs", root, root + "/db"]
        let process = Process(); let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", sb, "/usr/bin/python3", "-c", script,
                             String(decoding: try JSONEncoder().encode(probes), as: UTF8.self)]
        process.environment = ["PATH":"/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE":"1"]
        process.standardOutput = out; process.standardError = FileHandle.standardError
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        // Allowed subpaths + ancestors stat cleanly; a sibling control dir stays hidden.
        XCTAssertEqual(try JSONDecoder().decode([Bool].self, from: data),
                       [true, true, true, true, false])
    }

    func testKimiCanRefreshOnlyCanonicalCredentialDirectory() throws {
        let root = "/private/tmp/kimi-credential-sandbox-" + UUID().uuidString
        let work = root + "/workshop/writer-runs/one/workspace"
        let profile = root + "/workshop/profiles/clean-v2/kimi"
        let credentials = root + "/canonical/credentials"
        let unrelated = root + "/canonical/unrelated"
        for path in [work, profile, credentials, unrelated] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let policy = root + "/workshop/policy.sb"
        try ProfileBuilder.writerSandboxProfile(
            workshopHome: root + "/workshop", worktree: work, profile: profile,
            token: root + "/workshop/profiles/kimi/token", destination: policy,
            engineer: .kimi, kimiCredentialPath: credentials)
        let script = """
        import os,sys,json
        result=[]
        for path in json.loads(sys.argv[1]):
            try:
                fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.close(fd);result.append(True)
            except OSError:result.append(False)
        print(json.dumps(result))
        """
        let targets = [credentials + "/refresh-probe", unrelated + "/denied"]
        let process = Process(); let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", policy, "/usr/bin/python3", "-c", script,
                             String(decoding: try JSONEncoder().encode(targets), as: UTF8.self)]
        process.environment = ["PATH":"/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE":"1"]
        process.standardOutput = out; process.standardError = FileHandle.standardError
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try JSONDecoder().decode([Bool].self, from: data), [true, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets[1]))
    }

    func testKimiCanReadPriorWorkspaceButCannotWriteItOrReadPeer() throws {
        let root = "/private/tmp/kimi-reload-sandbox-" + UUID().uuidString
        let work = root + "/writer-runs/current/workspace"
        let prior = root + "/writer-runs/prior/workspace"
        let peer = root + "/writer-runs/peer/workspace"
        let profile = root + "/profiles/clean-v2/kimi"
        for path in [work, prior, peer, profile] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try "previous".write(toFile: prior + "/context", atomically: true, encoding: .utf8)
        try "other".write(toFile: peer + "/context", atomically: true, encoding: .utf8)
        let policy = root + "/policy.sb"
        try ProfileBuilder.writerSandboxProfile(
            workshopHome: root, worktree: work, profile: profile,
            token: root + "/profiles/kimi/token", destination: policy,
            engineer: .kimi, readOnlyPriorWorkspace: prior)
        let script = """
        import os,sys,json
        prior,peer=sys.argv[1:]
        result=[]
        for path in [prior+'/context',peer+'/context']:
            try: open(path).read();result.append(True)
            except OSError: result.append(False)
        try: os.stat(os.path.dirname(prior));result.append(True)
        except OSError: result.append(False)
        try: open(prior+'/new','w').close();result.append(True)
        except OSError: result.append(False)
        print(json.dumps(result))
        """
        let process = Process(); let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", policy, "/usr/bin/python3", "-c", script, prior, peer]
        process.environment = ["PATH":"/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE":"1"]
        process.standardOutput = out; process.standardError = FileHandle.standardError
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try JSONDecoder().decode([Bool].self, from: data),
                       [true, false, true, false])
    }
}
