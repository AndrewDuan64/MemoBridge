import Darwin
import Foundation

private struct AudioLinkRemovalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AudioLinkManager {
    /// Legacy builds could persist an explicitly disabled preference while
    /// leaving the link behind. A missing preference is a fresh install.
    @discardableResult
    static func cleanupPreviouslyDisabled(in dataDirectory: URL, sourceDirectories: [URL], enabledPreference: Bool?) throws -> Bool {
        guard enabledPreference == false else { return false }
        return try remove(in: dataDirectory, sourceDirectories: sourceDirectories)
    }

    /// Remove the optional directory link only when it still names an expected
    /// Voice Memos location. Never follow the final path component for deletion.
    @discardableResult
    static func remove(in dataDirectory: URL, sourceDirectories: [URL]) throws -> Bool {
        let fm = FileManager.default
        let directory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let sources = sourceDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        for source in sources {
            let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
            guard directory.path != source.path && !directory.path.hasPrefix(prefix) else {
                throw AudioLinkRemovalError(message: "The data folder cannot be inside Voice Memos.")
            }
        }

        let link = directory.appendingPathComponent(linkName)
        var initial = stat()
        if lstat(link.path, &initial) != 0 {
            if errno == ENOENT { return false }
            throw AudioLinkRemovalError(message: "Cannot inspect the Voice Memos link: \(String(cString: strerror(errno))).")
        }
        guard (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) else {
            throw AudioLinkRemovalError(message: "The Voice Memos item is not a symbolic link; it was kept.")
        }
        let destination: String
        do { destination = try fm.destinationOfSymbolicLink(atPath: link.path) }
        catch { throw AudioLinkRemovalError(message: "Cannot read the Voice Memos link; it was kept.") }
        let target = URL(fileURLWithPath: destination, relativeTo: directory)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard sources.contains(target) else {
            throw AudioLinkRemovalError(message: "The Voice Memos link points elsewhere; it was kept.")
        }

        // A symbolic link cannot be edited in place. Recheck its inode before
        // unlinking so a concurrently replaced item is normally detected.
        var current = stat()
        guard lstat(link.path, &current) == 0,
              (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK),
              current.st_dev == initial.st_dev, current.st_ino == initial.st_ino else {
            throw AudioLinkRemovalError(message: "The Voice Memos link changed; it was kept.")
        }
        // unlink removes the link itself; it does not follow or delete its target.
        guard unlink(link.path) == 0 else {
            throw AudioLinkRemovalError(message: "Cannot remove the Voice Memos link: \(String(cString: strerror(errno))).")
        }
        return true
    }
}
