import Foundation
import Testing
@testable import RunnerForge

/// The sweeper is the one component where a bug in EITHER direction is
/// expensive: deleting a base image costs an hour, and keeping a job workspace
/// fills the disk. The policy is pure data and pure functions precisely so it
/// can be proven here without a Tart install.
@Suite("SweeperPolicy")
struct SweeperPolicyTests {

    @Test("docker system prune is forbidden in every spelling",
          arguments: [
            "docker system prune",
            "docker system prune -a",
            "docker system prune --all --volumes",
            "DOCKER SYSTEM PRUNE -A",
            "docker  system prune -af",
          ])
    func systemPruneIsForbidden(command: String) {
        #expect(SweeperPolicy.isForbiddenPrune(command))
    }

    /// `docker image prune -a` deletes every image not currently used by a
    /// container, which on this machine means the base images.
    @Test("image prune with -a is forbidden")
    func imagePruneAllIsForbidden() {
        #expect(SweeperPolicy.isForbiddenPrune("docker image prune -a"))
        #expect(SweeperPolicy.isForbiddenPrune("docker image prune -a -f"))
    }

    @Test("the allowed prune commands are allowed",
          arguments: SweeperPolicy.allowedPruneCommands)
    func allowedPrunesPass(command: String) {
        #expect(!SweeperPolicy.isForbiddenPrune(command))
    }

    /// The allow-list itself is asserted, so widening it is a deliberate edit to
    /// a test rather than an unnoticed change in behaviour.
    @Test("the allow-list has not grown")
    func allowListIsExactlyTwoCommands() {
        #expect(SweeperPolicy.allowedPruneCommands == [
            "docker image prune -f",
            "docker builder prune -f",
        ])
    }

    @Test("cache volumes are KEEP", arguments: SweeperPolicy.keepVolumes)
    func cacheVolumesAreKept(name: String) {
        #expect(SweeperPolicy.isKeepItem(name, tartTag: "26.0"))
    }

    @Test("the configured Tart image and its upstream base are KEEP")
    func tartImagesAreKept() {
        #expect(SweeperPolicy.isKeepItem("runnerforge-macos:26.0", tartTag: "26.0"))
        #expect(SweeperPolicy.isKeepItem("ghcr.io/cirruslabs/macos-tahoe-xcode:26", tartTag: "26.0"))
    }

    /// A Tart IMAGE is never deletable; only a per-job CLONE is. The prefix is
    /// the whole distinction, so it gets its own test.
    @Test("only forge- clones are deletable")
    func onlyClonesAreDeletable() {
        #expect(SweeperPolicy.isDeletableTartEntry("forge-mac-build-0-1712345678"))
        #expect(!SweeperPolicy.isDeletableTartEntry("runnerforge-macos:26.0"))
        #expect(!SweeperPolicy.isDeletableTartEntry("ghcr.io/cirruslabs/macos-tahoe-xcode:26"))
        #expect(!SweeperPolicy.isDeletableTartEntry("sonoma-base"))
    }

    /// A clone is named for deletion and an image is named for keeping. If one
    /// name ever satisfied both, the sweeper would be ambiguous.
    @Test("nothing is both KEEP and deletable")
    func keepAndDeleteAreDisjoint() {
        let candidates = SweeperPolicy.keepVolumes
            + SweeperPolicy.keepTartImages(tag: "26.0")
            + ["forge-mac-build-0-1", "forge-fetchcontent"]

        for name in candidates {
            let keep = SweeperPolicy.isKeepItem(name, tartTag: "26.0")
            let deletable = SweeperPolicy.isDeletableTartEntry(name)
            #expect(!(keep && deletable), "\(name) is both KEEP and deletable")
        }
    }

    @Test("purge directories are relative, never absolute")
    func purgeDirectoriesAreRelative() {
        for entry in SweeperPolicy.purgeDirectories {
            #expect(!entry.relative.hasPrefix("/"),
                    "\(entry.relative) would escape the work directory")
            #expect(!entry.relative.contains(".."),
                    "\(entry.relative) would escape the work directory")
            #expect(!entry.description.isEmpty)
        }
    }
}
