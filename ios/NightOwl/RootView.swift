import NightOwlAnalysis
import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TonightTab().tag(0).tabItem { Label("Last night", systemImage: "moon.stars.fill") }
            TrendsView().tag(1).tabItem { Label("Trends", systemImage: "chart.bar.fill") }
            HistoryView().tag(2).tabItem { Label("History", systemImage: "calendar") }
        }
        .onChange(of: store.openNight) { _, n in if n != nil { tab = 0; store.openNight = nil } }   // nil again so the next one registers
        .task { await store.refresh() }
    }
}

struct TonightTab: View {
    @Environment(Store.self) private var store
    @State private var settings = false

    var body: some View {
        NavigationStack {
            Group {
                if let n = store.latest {
                    NightView(night: n).refreshable { await store.refresh() }
                } else {
                    Welcome()
                }
            }
            .safeAreaInset(edge: .top) { WakeCard() }
            .navigationTitle("Night Owl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.loading { ProgressView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let e = store.error, store.hasFolder {
                    Text(e).font(.caption).padding(10).frame(maxWidth: .infinity)
                        .background(.red.opacity(0.25))
                }
            }
            .sheet(isPresented: $settings) { SettingsView() }
        }
    }
}

/// Progress of "I'm up" on this iPhone: which step, how far overall, how long
/// so far and roughly how long to go, and a warning if it stops moving.
struct JobCard: View {
    let job: Store.Job

    var body: some View {
        TimelineView(.periodic(from: job.started, by: 1)) { context in
            let now = context.date
            let elapsed = now.timeIntervalSince(job.started)
            let idle = now.timeIntervalSince(job.lastProgress)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Building your report on this iPhone").font(.subheadline.weight(.semibold))
                        Text("Step \(job.step) of \(Store.Job.steps) · \(job.stage)")
                            .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                    Spacer()
                }
                ProgressView(value: job.overall).tint(Theme.amber)
                Text(timing(elapsed: elapsed))
                    .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                if idle >= 45 {
                    Text("Nothing has moved for \(Self.clock(idle)). "
                         + (job.inBackground ? "iOS may be holding it back; it should pick up again."
                                             : "iOS pauses it when Night Owl isn't on screen. Keep the app open."))
                        .font(.caption).foregroundStyle(Theme.amber)
                }
                Text(job.inBackground ? "You can lock your phone or switch apps; it keeps going."
                                      : "Keep Night Owl open until this finishes. Locking the phone or switching apps pauses it.")
                    .font(.caption2).foregroundStyle(Theme.muted)
                if !job.inBackground, #available(iOS 26, *), let why = ContinuedJob.lastRefusal {
                    Text("iOS said no to running it in the background: \(why)")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: 14))
        .padding(.horizontal).padding(.top, 6)
    }

    /// "42% · 1:23 so far · about 2 min to go" (no guess until there's enough to go on)
    private func timing(elapsed: TimeInterval) -> String {
        var parts = ["\(Int(job.overall * 100))%", "\(Self.clock(elapsed)) so far"]
        if job.overall >= 0.05, elapsed >= 10, job.overall < 1 {
            let left = elapsed * (1 - job.overall) / job.overall
            parts.append(left < 60 ? "under a minute to go" : "about \(Int((left / 60).rounded())) min to go")
        }
        return parts.joined(separator: " · ")
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// "I'm up": stop the Pi and get the report now instead of at 12:15.
struct WakeCard: View {
    @Environment(Store.self) private var store
    @State private var sending = false

    var body: some View {
        TimelineView(.everyMinute) { _ in
            VStack(spacing: 0) {
                cards
                if store.hasPi, store.job == nil, store.piStatus?.recording == false { StartCard() }
            }
        }
        // the Pi's own word on whether it's recording, kept fresh while this is on screen
        .task {
            while !Task.isCancelled {
                await store.refreshPiStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder private var cards: some View {
            if let job = store.job {
                JobCard(job: job)
            } else if store.hasFolder, store.waitingForReport {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Building your report").font(.subheadline.weight(.semibold))
                        Text("Recording stopped. Your Mac is copying and analyzing it; that takes a few minutes once it's awake.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Theme.card, in: .rect(cornerRadius: 14))
                .padding(.horizontal).padding(.top, 6)
                .task {
                    while !Task.isCancelled, store.waitingForReport {
                        try? await Task.sleep(for: .seconds(20))
                        await store.refresh()
                    }
                }
            } else if store.hasFolder || store.hasPi, !store.hasTodaysNight || store.piStatus?.recording == true {
                // Here until today's report is in, even past noon, and whenever the Pi is
                // recording (a nap after the morning report). When it isn't recording it
                // just fetches the latest night (never stops the Pi, which would cancel
                // the coming night)
                let recording = store.inRecordingWindow
                Button {
                    sending = true
                    Task {
                        // with the Pi set up, this iPhone does it all; otherwise ask the Mac via iCloud
                        if store.hasPi { await store.analyzeOnPhone(stopFirst: recording) }
                        else if recording { await store.wake() }
                        else { await store.refresh() }
                        sending = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "sun.max.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("I'm up").font(.headline)
                            Text(store.phoneRunUnfinished ? "The last try didn't finish. Tap to pick up where it left off"
                                 : recording ? "Recording until \(store.stopTime). Tap to stop and get the report"
                                 : "Get last night's report")
                                .font(.caption).opacity(0.75)
                        }
                        Spacer()
                        if sending { ProgressView().tint(.black) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(Theme.amber, in: .rect(cornerRadius: 14))
                    .foregroundStyle(.black)
                }
                .disabled(sending)
                .padding(.horizontal).padding(.top, 6)
            }
    }
}

/// "Start recording": the Pi records from now until the stop time, whatever the hour.
struct StartCard: View {
    @Environment(Store.self) private var store
    @State private var starting = false

    var body: some View {
        Button {
            starting = true
            Task { await store.startRecording(); starting = false }
        } label: {
            HStack {
                Image(systemName: "record.circle")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start recording").font(.headline)
                    Text("The Pi records until \(store.stopTime)").font(.caption).opacity(0.75)
                }
                Spacer()
                if starting { ProgressView() }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Theme.card, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(starting)
        .padding(.horizontal).padding(.top, 6)
    }
}

struct HistoryView: View {
    @Environment(Store.self) private var store

    var body: some View {
        NavigationStack {
            List(store.nights.reversed()) { n in
                NavigationLink(value: n) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.date.dayLabel).font(.body.weight(.medium))
                            Text("\(duration(ms: n.snoreMs)) snoring · \(n.percentOfNight)% of \(duration(ms: n.recordedMs))")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        ScorePill(score: n.score, band: n.band)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sky.ignoresSafeArea())
            .navigationTitle("History")
            .navigationDestination(for: Night.self) { n in
                NightView(night: n).navigationTitle(n.date.dayLabel).navigationBarTitleDisplayMode(.inline)
            }
            .refreshable { await store.refresh() }
            .overlay { if store.nights.isEmpty { ContentUnavailableView("No nights yet", systemImage: "moon.zzz") } }
        }
    }
}

struct FolderButton: View {
    @Environment(Store.self) private var store
    @State private var picking = false
    var title = "Choose NightOwl folder"
    var body: some View {
        Button(title) { picking = true }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { store.setFolder(url) }
            }
    }
}

struct Welcome: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "moon.stars.fill").font(.system(size: 56)).foregroundStyle(Theme.amber)
            Text("Night Owl").font(.largeTitle.weight(.bold))
            if store.hasFolder {
                Text(store.error ?? "Waiting for the first night from your Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                Button("Try again") { Task { await store.refresh() } }
            } else {
                Text("Your Mac puts each night in iCloud Drive › NightOwl. Pick that folder once and the app keeps up from there.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                FolderButton().buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(Theme.sky.ignoresSafeArea())
    }
}

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Data") {
                    FolderButton(title: "Change NightOwl folder")
                    Button("Refresh now") { Task { await store.refresh() } }
                    LabeledContent("Nights", value: "\(store.nights.count)")
                }
                PiSection()
                if store.hasPi { ScheduleSection() }
                Section("Snore Score") {
                    Text("5 × minutes of snoring per hour recorded, plus 1 per possible gasp, capped at 100. Lower is quieter.")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Settings: let this iPhone fetch and analyze nights itself.
struct PiSection: View {
    @Environment(Store.self) private var store
    @State private var host = ""
    @State private var token = ""
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        Section {
            TextField("Pi address", text: $host, prompt: Text(PiClient.defaultHost))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(store.hasPi ? "Token saved (paste to replace)" : "Paste the Pi token", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(testing ? "Testing…" : "Save and test") {
                if !token.isEmpty || host != store.piHost { store.setPi(host: host, token: token.isEmpty ? (store.piToken ?? "") : token) }
                token = ""
                testing = true
                Task { result = await store.testPi(); testing = false }
            }
            .disabled(testing || (token.isEmpty && !store.hasPi))
            if let result { Text(result).font(.callout).foregroundStyle(Theme.muted) }
            Button("Analyze the latest night on the Pi now") {
                Task { await store.analyzeOnPhone(stopFirst: false) }
            }
            .disabled(!store.hasPi || store.job != nil)
        } header: {
            Text("Analyze on this iPhone")
        } footer: {
            Text("With this set up, \"I'm up\" stops the Pi, downloads the night and builds the report on this iPhone, no Mac needed. Your Mac still copies each night at 12:15 as a backup. The token is on the Pi: run  ssh nightowl cat nightowl/server.token  on your Mac and paste it here.")
        }
        .onAppear { host = store.piHost == PiClient.defaultHost ? "" : store.piHost }
    }
}

/// Settings: when the Pi records on its own.
struct ScheduleSection: View {
    @Environment(Store.self) private var store
    @State private var auto = true
    @State private var start = Date()
    @State private var end = Date()
    @State private var result: String?
    @State private var saving = false

    /// The Pi keeps Toronto time whatever zone this phone is in.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Audio.timeZone
        return f
    }()

    var body: some View {
        Section {
            Toggle("Record every night", isOn: $auto)
            DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute).disabled(!auto)
            DatePicker("Stops", selection: $end, displayedComponents: .hourAndMinute)
            Button(saving ? "Saving…" : "Save schedule") {
                saving = true
                let s = PiClient.Schedule(auto: auto, start: Self.clock.string(from: start), end: Self.clock.string(from: end))
                Task { result = await store.saveSchedule(s); saving = false }
            }
            .disabled(saving)
            if let result { Text(result).font(.callout).foregroundStyle(Theme.muted) }
        } header: {
            Text("Recording schedule")
        } footer: {
            Text("Times are the Pi's (Toronto). Start recording on the main screen also records until the stop time, whenever you tap it. A change applies from the next recording.")
        }
        .environment(\.timeZone, Audio.timeZone)
        .task {
            await store.refreshPiStatus()
            let s = store.piStatus?.schedule ?? Store.cachedSchedule
            auto = s.auto
            start = Self.clock.date(from: s.start) ?? start
            end = Self.clock.date(from: s.end) ?? end
        }
    }
}
