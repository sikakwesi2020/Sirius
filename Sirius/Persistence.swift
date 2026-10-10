import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview = PersistenceController(inMemory: true)

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Sirius")
        container.persistentStoreDescriptions.forEach {
            $0.shouldMigrateStoreAutomatically = true
            $0.shouldInferMappingModelAutomatically = true
            if inMemory { $0.url = URL(fileURLWithPath: "/dev/null") }
        }
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Core Data store failed to load: \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}
