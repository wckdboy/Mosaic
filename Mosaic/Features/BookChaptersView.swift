import SwiftUI

// Chapter titles are the difference between a pile of pages and a book. The planner
// proposes a place or theme for each event; this sheet lets the person rename any
// chapter without changing the underlying photo order.
struct BookChaptersView: View {
    @Binding var plan: CoreBookPlan?
    @Binding var project: CreationProject
    @Environment(\.dismiss) private var dismiss

    private var events: [CoreBookEvent] { plan?.events ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    ContentUnavailableView(
                        "No chapters yet", systemImage: "book.pages",
                        description: Text("Add photos and Mosaic will group them by time and place."))
                } else {
                    List {
                        Section {
                            ForEach(events) { event in
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField(
                                        "Chapter title", text: titleBinding(event)
                                    )
                                    .font(.headline)
                                    HStack(spacing: 6) {
                                        Text(dateRange(event))
                                        Text("·")
                                        Text("\(event.itemCount) photos")
                                        if let place = event.place, !place.isEmpty {
                                            Text("·")
                                            Text(place)
                                        }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                        } footer: {
                            Text(
                                "Titles follow the photos. Renaming a chapter updates its opening page; the cover title is edited in Book settings."
                            )
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func titleBinding(_ event: CoreBookEvent) -> Binding<String> {
        Binding(
            get: { project.eventTitles?[String(event.index)] ?? event.title },
            set: { newValue in
                var titles = project.eventTitles ?? [:]
                titles[String(event.index)] = newValue
                project.eventTitles = titles
                guard var current = plan, current.events.indices.contains(event.index) else { return }
                current.events[event.index].title = newValue
                let start = current.events[event.index].pageStart
                if current.pages.indices.contains(start), current.pages[start].kind == "page" {
                    current.pages[start].title = newValue
                }
                plan = current
            })
    }

    private func dateRange(_ event: CoreBookEvent) -> String {
        let start = Date(timeIntervalSince1970: event.startDate)
        let end = Date(timeIntervalSince1970: event.endDate)
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return start.formatted(date: .abbreviated, time: .omitted)
        }
        return
            "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }
}
