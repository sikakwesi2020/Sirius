import Foundation
import PDFKit

/// A deterministic, agent-friendly representation of one PDF bookmark.
struct PDFSection: Identifiable, Equatable, Sendable {
    /// Stable within a document as long as its bookmark order does not change (for example, `1.2.0`).
    let id: String
    let title: String
    /// Human-readable, one-based page number.
    let startPage: Int
    /// Inclusive, one-based page number.
    let endPage: Int
    let children: [PDFSection]
}

struct ExtractedPDFSection: Equatable, Sendable {
    let section: PDFSection
    let text: String
}

enum PDFSectionExtractorError: LocalizedError {
    case unreadableDocument
    case noBookmarks
    case sectionNotFound(String)
    case pagesUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unreadableDocument: "The selected file could not be opened as a PDF."
        case .noBookmarks: "This PDF does not contain bookmarks."
        case .sectionNotFound(let id): "No PDF section has the bookmark ID \(id)."
        case .pagesUnavailable(let title): "The pages for \(title) could not be read."
        }
    }
}

/// Extracts a PDF's bookmark tree and the text covered by any bookmark.
///
/// Range rules are intentionally deterministic:
/// - a section starts at its bookmark destination;
/// - it ends immediately before the next sibling bookmark;
/// - the final sibling inherits its parent's end, or the end of the document.
final class PDFSectionExtractor {
    func tableOfContents(from url: URL) throws -> [PDFSection] {
        try withDocument(at: url) { document in
            try makeTableOfContents(for: document)
        }
    }

    func subsections(of sectionID: String, in url: URL) throws -> [PDFSection] {
        let sections = try tableOfContents(from: url)
        guard let section = Self.find(sectionID, in: sections) else {
            throw PDFSectionExtractorError.sectionNotFound(sectionID)
        }
        return section.children
    }

    func extract(sectionID: String, from url: URL) throws -> ExtractedPDFSection {
        try withDocument(at: url) { document in
            let sections = try makeTableOfContents(for: document)
            guard let section = Self.find(sectionID, in: sections) else {
                throw PDFSectionExtractorError.sectionNotFound(sectionID)
            }

            let pageIndices = (section.startPage - 1)...(section.endPage - 1)
            let pages = pageIndices.compactMap { document.page(at: $0)?.string }
            guard !pages.isEmpty else {
                throw PDFSectionExtractorError.pagesUnavailable(section.title)
            }
            return ExtractedPDFSection(section: section, text: pages.joined(separator: "\n\n"))
        }
    }

    private func makeTableOfContents(for document: PDFDocument) throws -> [PDFSection] {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else {
            throw PDFSectionExtractorError.noBookmarks
        }
        let drafts = (0..<root.numberOfChildren).compactMap { index in
            root.child(at: index).map { makeDraft(from: $0, path: [index], document: document) }
        }
        let sections = resolve(drafts, inheritedEnd: document.pageCount)
        guard !sections.isEmpty else { throw PDFSectionExtractorError.noBookmarks }
        return sections
    }

    private func makeDraft(from outline: PDFOutline, path: [Int], document: PDFDocument) -> Draft {
        let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        let pageIndex = destination?.page.map(document.index(for:))
        let children = (0..<outline.numberOfChildren).compactMap { index in
            outline.child(at: index).map { makeDraft(from: $0, path: path + [index], document: document) }
        }
        return Draft(
            id: path.map(String.init).joined(separator: "."),
            title: outline.label?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled section",
            pageIndex: pageIndex,
            children: children
        )
    }

    private func resolve(_ drafts: [Draft], inheritedEnd: Int) -> [PDFSection] {
        drafts.enumerated().compactMap { index, draft in
            guard let start = draft.effectiveStart else { return nil }
            let nextStart = drafts.dropFirst(index + 1).compactMap(\.effectiveStart).first
            let endExclusive = max(start + 1, min(nextStart ?? inheritedEnd, inheritedEnd))
            return PDFSection(
                id: draft.id,
                title: draft.title,
                startPage: start + 1,
                endPage: endExclusive,
                children: resolve(draft.children, inheritedEnd: endExclusive)
            )
        }
    }

    private static func find(_ id: String, in sections: [PDFSection]) -> PDFSection? {
        for section in sections {
            if section.id == id { return section }
            if let match = find(id, in: section.children) { return match }
        }
        return nil
    }

    private func withDocument<T>(at url: URL, operation: (PDFDocument) throws -> T) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw PDFSectionExtractorError.unreadableDocument
        }
        return try operation(document)
    }

    private struct Draft {
        let id: String
        let title: String
        let pageIndex: Int?
        let children: [Draft]

        var effectiveStart: Int? {
            pageIndex ?? children.lazy.compactMap(\.effectiveStart).first
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
