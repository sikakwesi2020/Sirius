//
//  SiriusApp.swift
//  Sirius
//
//  Created by MAXWELL TAWIAH on 10/9/26.
//

import SwiftUI
import CoreData

@main
struct SiriusApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
