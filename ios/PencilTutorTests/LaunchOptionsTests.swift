import XCTest
@testable import PencilTutor

/// The night-time safety net: on 2026-11-28 a test run spoke through a simulator on the Mac's speakers. Under XCTest every sound
/// must be muted (volume 0), without needing a launch argument. Run this one alone before any other test.
final class LaunchOptionsTests: XCTestCase {
    func testEverySoundIsMutedUnderXCTestWithoutTheSilentArgument() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"], "this test runs under XCTest")
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("--silent"), "no launch argument is needed")
        XCTAssertTrue(LaunchOptions.mutesSound, "speech and the streaming player play at volume 0 under XCTest")
        XCTAssertFalse(LaunchOptions.silent, "silent is only the launch argument (it also skips live voice)")
    }
}
