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

    func testNativeStateSQLiteWALAndReopenInsideWriterSandbox() throws {
        let root = "/private/tmp/workshop-sqlite-" + UUID().uuidString
        let work = root + "/writer-runs/one/workspace"
        let profile = root + "/profiles/clean-v2/devin"
        let state = profile + "/data/devin/cli"
        let fm = FileManager.default
        for path in [work, state, root + "/db", root + "/writer-snapshots/accepted"] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        for path in [root + "/private-marker", root + "/profiles/private-marker", root + "/profiles/clean-v2/private-marker"] {
            try "PROTECTED_FIXTURE".write(toFile: path, atomically: true, encoding: .utf8)
        }
        let sandbox = root + "/policy.sb"
        try ProfileBuilder.writerSandboxProfile(workshopHome: root, worktree: work,
            profile: profile, token: root + "/writer-runs/one/token", destination: sandbox)
        let script = """
        import sqlite3,sys,pathlib,json
        state=pathlib.Path(sys.argv[1]); db=state/'sessions.db'
        connection=sqlite3.connect(str(db))
        assert connection.execute('PRAGMA journal_mode=WAL').fetchone()[0]=='wal'
        connection.execute('CREATE TABLE marker(value TEXT NOT NULL)')
        connection.execute('INSERT INTO marker VALUES (?)',('WORKSHOP_STATE_MARKER',))
        connection.commit()
        assert pathlib.Path(str(db)+'-wal').exists()
        assert pathlib.Path(str(db)+'-shm').exists()
        second=sqlite3.connect(str(db))
        assert second.execute('SELECT value FROM marker').fetchone()[0]=='WORKSHOP_STATE_MARKER'
        assert second.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        second.close(); connection.close()
        reopened=sqlite3.connect(str(db))
        assert reopened.execute('SELECT value FROM marker').fetchone()[0]=='WORKSHOP_STATE_MARKER'
        reopened.close()
        root=state.parents[5]
        for ancestor in [root,root/'profiles',root/'profiles/clean-v2']:
            assert ancestor.stat().st_mode
            try:
                list(ancestor.iterdir())
            except PermissionError:
                pass
            else:
                raise AssertionError('ancestor directory listing allowed')
            for action in [lambda: (ancestor/'private-marker').read_text(),lambda: (ancestor/'private-marker').write_text('CHANGED')]:
                try:
                    action()
                except PermissionError:
                    pass
                else:
                    raise AssertionError('ancestor content access allowed')
        for path in sys.argv[2:]:
            try:
                pathlib.Path(path).write_text('DENIED_FIXTURE')
            except PermissionError:
                continue
            raise AssertionError('protected write was allowed')
        print(json.dumps({'sqlite_create_wal_reopen': True, 'protected_writes_denied': True}))
        """
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", sandbox, "/usr/bin/python3", "-c", script, state,
            root + "/db/denied", root + "/writer-snapshots/accepted/denied"]
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
        process.currentDirectoryURL = URL(fileURLWithPath: work)
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let result = try JSONDecoder().decode([String: Bool].self, from: data)
        XCTAssertEqual(result["sqlite_create_wal_reopen"], true)
        XCTAssertEqual(result["protected_writes_denied"], true)
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
        // The user's real credential store must never be writable from a
        // sandboxed turn — a failed refresh would wipe shared credentials.
        XCTAssertFalse(text.contains(".kimi-code/credentials"))
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
}
