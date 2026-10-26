import SwiftUI
import PerryBrain

struct PerryEditorView: View {
    enum Cadence: String, CaseIterable, Identifiable {
        case onRequest, once, daily, interval
        var id: String { rawValue }
        var title: String {
            switch self {
            case .onRequest: "Only when you ask"
            case .once: "Once"
            case .daily: "Every day"
            case .interval: "Every few hours"
            }
        }
    }

    let perry: Perry?
    @ObservedObject var model: HomeModel
    let store: PerryStore

    @State private var name = ""
    @State private var job = ""
    @State private var cadence = Cadence.onRequest
    @State private var dailyTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var hours = 4
    @State private var onceDate = Date().addingTimeInterval(3600)
    @State private var paused = false
    @State private var memory = ""
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @FocusState private var jobFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section {
                TextField("What to do", text: $job, prompt: Text("What should this helper do?"), axis: .vertical)
                    .lineLimit(2...5)
                    .labelsHidden()
                    .focused($jobFocused)
                TextField("Name", text: $name, prompt: Text(job.isEmpty ? "Optional" : PerryNameGenerator.twoWordName(for: job)))
            }
            Section("When it runs") {
                Picker("Runs", selection: $cadence) {
                    ForEach(Cadence.allCases) { Text($0.title).tag($0) }
                }
                switch cadence {
                case .onRequest:
                    Text("Open this helper and ask it anything. It keeps its own conversation and memory.").settingNote()
                case .once:
                    DatePicker("On", selection: $onceDate, displayedComponents: [.date, .hourAndMinute])
                case .daily:
                    DatePicker("At", selection: $dailyTime, displayedComponents: .hourAndMinute)
                case .interval:
                    Stepper("Every \(hours) hour\(hours == 1 ? "" : "s")", value: $hours, in: 1...24)
                }
                if cadence != .onRequest, perry?.schedule != nil {
                    Toggle("Paused", isOn: $paused).toggleStyle(InkSwitchStyle())
                    if let failures = perry?.schedule?.consecutiveFailures, failures > 0 {
                        Text("The last \(failures) run\(failures == 1 ? "" : "s") failed. Perry pauses after three failures in a row.").settingNote()
                    }
                }
            }
            if perry != nil {
                Section("Memory") {
                    TextEditor(text: $memory)
                        .font(PerryTheme.Scale.body)
                        .frame(minHeight: 80)
                    Text("Notes this helper keeps between runs. Perry uses them only when memory is on in Settings.").settingNote()
                }
            }
            if let errorMessage {
                StatusLabel(errorMessage, .attention).settingNote()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
            HStack(spacing: PerryTheme.Spacing.inline) {
                if let perry {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .buttonStyle(InkButtonStyle(.destructive))
                        .notchDialog("Delete \(perry.name)?", isPresented: $confirmDelete,
                                     message: "Its schedule and memory are removed. Its past conversation stays in History.") {
                            [NotchDialog.Action("Delete helper", role: .destructive) { delete(perry) }]
                        }
                }
                Spacer()
                Button(perry == nil ? "Create helper" : "Save") { save() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .controlSize(.small)
        .task(id: perry?.id) {
            await load()
            if perry == nil {
                await Task.yield()
                jobFocused = true
            }
        }
    }

    private func load() async {
        guard let perry else { return }
        name = perry.name
        job = perry.job
        switch perry.schedule?.kind {
        case .daily(let hour, let minute)?:
            cadence = .daily
            dailyTime = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? dailyTime
        case .interval(let seconds)?:
            cadence = .interval
            hours = max(1, min(24, Int(seconds / 3600)))
        case .once(let date)?:
            cadence = .once
            onceDate = date
        case nil:
            cadence = .onRequest
        }
        paused = perry.schedule?.paused ?? false
        memory = await store.memory(for: perry.id)
    }

    private var schedule: RoutineSchedule? {
        let kind: RoutineSchedule.Kind
        switch cadence {
        case .onRequest:
            return nil
        case .once:
            kind = .once(onceDate)
        case .daily:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: dailyTime)
            kind = .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        case .interval:
            kind = .interval(TimeInterval(hours) * 3600)
        }
        guard var schedule = perry?.schedule, schedule.kind == kind else {
            var fresh = RoutineSchedule(kind: kind)
            fresh.paused = paused
            return fresh
        }
        if schedule.paused && !paused { schedule.consecutiveFailures = 0 }
        schedule.paused = paused
        return schedule
    }

    private func save() {
        let job = job.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = schedule
        let memory = memory
        let existing = perry
        Task {
            do {
                let saved: Perry
                if var existing {
                    existing.job = job
                    existing.name = name.isEmpty ? existing.name : name
                    existing.schedule = schedule
                    try await store.update(existing)
                    try await store.setMemory(memory, for: existing.id)
                    saved = existing
                } else {
                    saved = try await store.create(job: job, name: name.isEmpty ? nil : name, schedule: schedule)
                }
                model.perrys = await store.list()
                model.sidebarSelection = .perryEditor(saved.id)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ perry: Perry) {
        Task {
            do {
                try await store.remove(id: perry.id)
                model.perrys = await store.list()
                model.sidebarSelection = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
