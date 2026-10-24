import Foundation
import PerryGuide

// Lab seeder for the routine-replay drill. Emits one reviewed routine
// through the production `RoutineDocument` encoder so the seeded document
// can never drift from the real wire format. Usage:
//   seed-routine <storage-dir> <bundle-id> <probe-text>
// Writes <storage-dir>/Routines/<uuid>.md targeting `AXTextArea` with a
// literal typeText step.

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: seed-routine <storage-dir> <bundle-id> <probe-text>\n".data(using: .utf8)!)
    exit(2)
}
let (storage, bundleID, probeText) = (args[1], args[2], args[3])

let routine = try LearnedRoutine(
    name: "Type the replay probe",
    appBundleIDs: [bundleID],
    steps: [
        RoutineStep(
            summary: "Type the replay probe into the document",
            target: RoutineTarget(role: "AXTextArea"),
            action: .typeText(.literal(probeText))
        )
    ],
    provenance: .reviewed
)
let store = RoutineStore(storageDirectory: URL(fileURLWithPath: storage))
try store.save(routine)
print(routine.id.uuidString)
