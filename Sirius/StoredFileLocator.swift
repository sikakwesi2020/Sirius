import Foundation

enum StoredFileLocator {
    static func applicationSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func relativePath(for url: URL) -> String {
        relativePath(from: url.path) ?? url.lastPathComponent
    }

    static func resolve(_ storedPath: String) throws -> URL {
        let manager = FileManager.default
        if storedPath.hasPrefix("/"), manager.fileExists(atPath: storedPath) {
            return URL(fileURLWithPath: storedPath)
        }
        let relative = relativePath(from: storedPath) ?? storedPath
        let resolved = try applicationSupport().appendingPathComponent(relative)
        guard manager.fileExists(atPath: resolved.path) else {
            throw StoredFileError.missing(relative)
        }
        return resolved
    }

    private static func relativePath(from path: String) -> String? {
        for root in ["StudyMaterials", "LessonAudio"] {
            if path == root || path.hasPrefix("\(root)/") { return path }
            if let range = path.range(of: "/\(root)/") {
                return String(path[range.lowerBound...].dropFirst())
            }
        }
        return nil
    }
}

enum StoredFileError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): "The saved file is missing from local storage: \(path)"
        }
    }
}
