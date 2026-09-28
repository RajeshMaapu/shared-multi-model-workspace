import Foundation
import WorkshopCore
import WorkshopService

/// Zero-inference credential checks per engineer (G-D1). Results feed the
/// engineer card via `CollaborationService.recordCredentialStatus`; token
/// values are never read into results or logs.
public enum CredentialCanary {
    public enum State: String, Sendable {
        case ok, missing, expired, unreadable
    }

    /// Run the canary for one engineer against `home` (WORKSHOP_HOME).
    /// Zero inference for every engineer: for kimi we only check that the
    /// OAuth grant file exists and still carries a `refresh_token` — the
    /// access token inside expires ~15 min after each CLI refresh and is
    /// renewed by the Kimi CLI at launch, never by Workshop.
    public static func check(
        engineer: EngineerID, home: String,
        kimiConfigPath: String? = nil, kimiCredentialsDir: String? = nil)
        async -> (State, String) {
        switch engineer {
        case .devin:
            // The profile links credentials.toml to the canonical file.
            let link = home + "/profiles/clean-v2/devin/data/devin/credentials.toml"
            let fm = FileManager.default
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: link, isDirectory: &isDir),
                  !isDir.boolValue else {
                return (.missing, "credentials.toml link absent")
            }
            guard let resolved = try? fm.destinationOfSymbolicLink(atPath: link)
                    ?? link else {
                return (.unreadable, "credentials.toml link unreadable")
            }
            let target = resolved.hasPrefix("/") ? resolved
                : (link as NSString).deletingLastPathComponent + "/" + resolved
            guard fm.isReadableFile(atPath: target) else {
                return (.unreadable, "credentials.toml target unreadable")
            }
            return (.ok, "credentials.toml resolves")
        case .kimi:
            // Profile credentials dir must be a directory link, and the OAuth
            // grant file must exist with a refresh_token. A short-lived or
            // expired access token is fine: the Kimi CLI renews it on launch.
            let link = home + "/profiles/clean-v2/kimi/credentials"
            var isDir = ObjCBool(false)
            let fm = FileManager.default
            if !fm.fileExists(atPath: link, isDirectory: &isDir) {
                return (.missing, "kimi credentials link absent")
            }
            if !isDir.boolValue {
                return (.unreadable, "kimi credentials link is not a directory")
            }
            let configPath = kimiConfigPath
                ?? NSHomeDirectory() + "/.kimi-code/config.toml"
            let credentialsDir = kimiCredentialsDir
                ?? NSHomeDirectory() + "/.kimi-code/credentials"
            do {
                let name = try KimiOAuthCredential.credentialFileName(
                    configPath: configPath)
                let path = credentialsDir + "/" + name + ".json"
                guard let data = fm.contents(atPath: path) else {
                    return (.missing, "oauth grant file absent")
                }
                guard let json = try? JSONDecoder()
                        .decode(JSONValue.self, from: data),
                      json["refresh_token"]?.stringValue.map({ !$0.isEmpty })
                        ?? false else {
                    return (.unreadable, "oauth grant missing refresh_token")
                }
                return (.ok, "credentials: ok — access token is refreshed by the Kimi CLI at launch")
            } catch {
                return (.unreadable, "oauth grant unreadable")
            }
        case .deepseek:
            do {
                _ = try DeepSeekAdapter.readCredential()
                return (.ok, "credential reference readable")
            } catch {
                return (.missing, "credential reference unreadable")
            }
        }
    }

    /// Run all (or only the live) engineers and report each result.
    public static func runAll(
        home: String, service: CollaborationService,
        only: Set<EngineerID>? = nil) async {
        for engineer in EngineerID.allCases where only?.contains(engineer) ?? true {
            let (state, detail) = await check(
                engineer: engineer, home: home)
            await service.recordCredentialStatus(engineer: engineer,
                                                 state: state.rawValue,
                                                 detail: detail)
        }
    }
}
