import Combine
import CoreData
import Foundation
import PDFKit

@MainActor
final class MaterialLibrary: ObservableObject {
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?

    private var context: NSManagedObjectContext?
    private let extractor = PDFSectionExtractor()

    func configure(context: NSManagedObjectContext) {
        self.context = context
        migrateStoredPaths(context: context)
    }

    func importPDF(from sourceURL: URL, subjectName: String) throws -> String {
        guard let context else { throw LibraryError.notConfigured }
        guard let subject = fetchSubject(named: subjectName, context: context) else {
            throw LibraryError.subjectNotFound(subjectName)
        }
        isImporting = true
        defer { isImporting = false }

        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }

        let directory = try materialsDirectory()
        let materialID = UUID()
        let destination = directory.appendingPathComponent("\(materialID.uuidString).pdf")
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        do {
            let outline = try extractor.tableOfContents(from: destination)
            guard let document = PDFDocument(url: destination) else { throw LibraryError.invalidPDF }
            let material = StudyMaterial(context: context)
            material.id = materialID
            material.title = sourceURL.deletingPathExtension().lastPathComponent
            material.localPath = StoredFileLocator.relativePath(for: destination)
            material.importedAt = Date()
            material.pageCount = Int32(document.pageCount)
            material.subject = subject

            var index: Int32 = 0
            store(outline, material: material, parentID: nil, depth: 0, index: &index, context: context)
            try context.save()
            return encode([
                "status": "imported",
                "material_id": materialID.uuidString,
                "title": material.title ?? "PDF",
                "page_count": document.pageCount,
                "bookmark_count": Int(index),
                "subject": subjectName
            ])
        } catch {
            try? FileManager.default.removeItem(at: destination)
            context.rollback()
            throw error
        }
    }

    func execute(_ call: GeminiLiveClient.ToolCall) throws -> String {
        switch call.name {
        case "list_materials": return try listMaterials(subject: call.args["subject"])
        case "get_pdf_outline": return try outline(materialID: required("material_id", in: call))
        case "extract_pdf_section":
            return try extract(
                materialID: required("material_id", in: call),
                sectionID: required("section_id", in: call),
                chunkIndex: Int(call.args["chunk_index"] ?? "0") ?? 0
            )
        default: throw LibraryError.unsupportedTool(call.name)
        }
    }

    private func listMaterials(subject: String?) throws -> String {
        guard let context else { throw LibraryError.notConfigured }
        let request = StudyMaterial.fetchRequest()
        if let subject, !subject.isEmpty {
            request.predicate = NSPredicate(format: "subject.name =[cd] %@", subject)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: false)]
        let values: [[String: Any]] = try context.fetch(request).compactMap { material in
            guard let id = material.id, let title = material.title, let subject = material.subject?.name else { return nil }
            let available = material.localPath.flatMap { try? StoredFileLocator.resolve($0) } != nil
            return ["material_id": id.uuidString, "title": title, "subject": subject,
                    "page_count": material.pageCount, "available": available]
        }
        return encode(["materials": values])
    }

    private func outline(materialID: String) throws -> String {
        let material = try fetchMaterial(id: materialID)
        let sections = sortedSections(for: material).map { section in
            [
                "section_id": section.bookmarkID ?? "",
                "title": section.title ?? "Untitled",
                "start_page": section.startPage,
                "end_page": section.endPage,
                "depth": section.depth,
                "parent_section_id": section.parentBookmarkID ?? NSNull()
            ] as [String: Any]
        }
        return encode(["material_id": materialID, "title": material.title ?? "PDF", "sections": sections])
    }

    private func extract(materialID: String, sectionID: String, chunkIndex: Int) throws -> String {
        let material = try fetchMaterial(id: materialID)
        guard let path = material.localPath else { throw LibraryError.materialNotFound(materialID) }
        let fileURL = try StoredFileLocator.resolve(path)
        let extracted = try extractor.extract(sectionID: sectionID, from: fileURL)
        let chunkSize = 40_000
        let characters = Array(extracted.text)
        let totalChunks = max(1, Int(ceil(Double(characters.count) / Double(chunkSize))))
        guard chunkIndex >= 0, chunkIndex < totalChunks else { throw LibraryError.invalidChunk(chunkIndex) }
        let start = chunkIndex * chunkSize
        let end = min(start + chunkSize, characters.count)
        let text = String(characters[start..<end])
        return encode([
            "material_id": materialID,
            "material_title": material.title ?? "PDF",
            "section_id": sectionID,
            "section_title": extracted.section.title,
            "start_page": extracted.section.startPage,
            "end_page": extracted.section.endPage,
            "content": text,
            "chunk_index": chunkIndex,
            "total_chunks": totalChunks,
            "has_more": chunkIndex + 1 < totalChunks
        ])
    }

    private func store(_ sections: [PDFSection], material: StudyMaterial, parentID: String?, depth: Int16,
                       index: inout Int32, context: NSManagedObjectContext) {
        for section in sections {
            let stored = MaterialSection(context: context)
            stored.id = UUID()
            stored.bookmarkID = section.id
            stored.title = section.title
            stored.startPage = Int32(section.startPage)
            stored.endPage = Int32(section.endPage)
            stored.depth = depth
            stored.parentBookmarkID = parentID
            stored.sortIndex = index
            stored.material = material
            index += 1
            store(section.children, material: material, parentID: section.id, depth: depth + 1, index: &index, context: context)
        }
    }

    private func sortedSections(for material: StudyMaterial) -> [MaterialSection] {
        let values = material.sections as? Set<MaterialSection> ?? []
        return values.sorted { $0.sortIndex < $1.sortIndex }
    }

    private func fetchSubject(named name: String, context: NSManagedObjectContext) -> SubjectProfile? {
        let request = SubjectProfile.fetchRequest()
        request.predicate = NSPredicate(format: "name =[cd] %@", name)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func fetchMaterial(id: String) throws -> StudyMaterial {
        guard let context, let uuid = UUID(uuidString: id) else { throw LibraryError.materialNotFound(id) }
        let request = StudyMaterial.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        guard let material = try context.fetch(request).first else { throw LibraryError.materialNotFound(id) }
        return material
    }

    private func materialsDirectory() throws -> URL {
        let base = try StoredFileLocator.applicationSupport()
        let directory = base.appendingPathComponent("StudyMaterials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func migrateStoredPaths(context: NSManagedObjectContext) {
        guard let materials = try? context.fetch(StudyMaterial.fetchRequest()) else { return }
        var changed = false
        for material in materials {
            guard let path = material.localPath, path.hasPrefix("/") else { continue }
            let relative = StoredFileLocator.relativePath(for: URL(fileURLWithPath: path))
            material.localPath = relative
            changed = true
        }
        if changed { try? context.save() }
    }

    private func required(_ key: String, in call: GeminiLiveClient.ToolCall) throws -> String {
        guard let value = call.args[key], !value.isEmpty else { throw LibraryError.missingArgument(key) }
        return value
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{\"error\":\"encoding failed\"}" }
        return string
    }
}

enum LibraryError: LocalizedError {
    case notConfigured, invalidPDF, subjectNotFound(String), materialNotFound(String), missingArgument(String), invalidChunk(Int), unsupportedTool(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "The material library is not ready."
        case .invalidPDF: "The selected file is not a readable PDF."
        case .subjectNotFound(let name): "No saved subject matches \(name)."
        case .materialNotFound(let id): "No imported material matches \(id)."
        case .missingArgument(let key): "The tool call is missing \(key)."
        case .invalidChunk(let index): "Content chunk \(index) is outside this section."
        case .unsupportedTool(let name): "The tool \(name) is not supported."
        }
    }
}
