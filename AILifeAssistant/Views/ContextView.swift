import SwiftData
import SwiftUI

/// Люди и проекты: контекст, вокруг которого крутятся записи.
///
/// Люди появляются сами, из речи. Проекты человек заводит осознанно:
/// придумывать их за него по одной фразе слишком самонадеянно, а вот
/// связывать записи с уже названным проектом разбор умеет.
struct ContextView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Person.mentionCount, order: .reverse)
    private var people: [Person]

    @Query(sort: \Project.name)
    private var projects: [Project]

    @State private var tab: Tab = .people
    @State private var isCreatingProject = false
    @State private var newProjectName = ""

    enum Tab: String, CaseIterable, Identifiable {
        case people, projects

        var id: String { rawValue }

        var title: String {
            switch self {
            case .people: return "Люди"
            case .projects: return "Проекты"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Раздел", selection: $tab) {
                    ForEach(Tab.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(DS.Spacing.md)

                switch tab {
                case .people: peopleList
                case .projects: projectsList
                }
            }
            .background(DS.Palette.background)
            .navigationTitle("Контекст")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }

                if tab == .projects {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            newProjectName = ""
                            isCreatingProject = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Новый проект")
                    }
                }
            }
            .alert("Новый проект", isPresented: $isCreatingProject) {
                TextField("Название", text: $newProjectName)
                Button("Отмена", role: .cancel) {}
                Button("Создать") { createProject() }
            } message: {
                Text("Записи, где встретится это название, свяжутся с проектом сами.")
            }
        }
    }

    // MARK: Люди

    @ViewBuilder
    private var peopleList: some View {
        if people.isEmpty {
            EmptyStateView(
                symbol: "person.2",
                title: "Людей пока нет",
                message: "Скажите «напомни позвонить Мише», и карточка появится здесь сама."
            )
            .frame(maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(spacing: DS.Spacing.xs) {
                    ForEach(people) { person in
                        NavigationLink {
                            PersonDetailView(person: person)
                        } label: {
                            personRow(person)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.lg)
            }
        }
    }

    private func personRow(_ person: Person) -> some View {
        SurfaceCard(padding: DS.Spacing.sm + 2) {
            HStack(spacing: DS.Spacing.sm) {
                // Инициал вместо аватара: фотографий у приложения нет,
                // а кружок с буквой узнаётся не хуже.
                ZStack {
                    Circle()
                        .fill(DS.Palette.accent.opacity(0.15))
                        .frame(width: 38, height: 38)

                    Text(String(person.name.prefix(1)).uppercased())
                        .font(DS.Font.entityTitle)
                        .foregroundStyle(DS.Palette.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(DS.Font.entityTitle)
                        .foregroundStyle(DS.Palette.textPrimary)

                    Text(Self.recordsText(person.totalMentions))
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Проекты

    @ViewBuilder
    private var projectsList: some View {
        if projects.isEmpty {
            VStack(spacing: DS.Spacing.md) {
                EmptyStateView(
                    symbol: "folder",
                    title: "Проектов пока нет",
                    message: "Заведите проект, и записи с его названием будут связываться с ним сами."
                )

                Button("Создать проект") {
                    newProjectName = ""
                    isCreatingProject = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, DS.Spacing.lg)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(spacing: DS.Spacing.xs) {
                    ForEach(projects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project)
                        } label: {
                            projectRow(project)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.lg)
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        SurfaceCard(padding: DS.Spacing.sm + 2) {
            HStack(spacing: DS.Spacing.sm) {
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(Color(projectHex: project.colorHex))
                    .frame(width: 6, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(DS.Font.entityTitle)
                        .foregroundStyle(DS.Palette.textPrimary)

                    Text(project.openItemsCount > 0
                         ? Self.recordsText(project.itemsCount) + ", открытых дел: \(project.openItemsCount)"
                         : Self.recordsText(project.itemsCount))
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Действия

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return }

        // Цвет назначается по названию, а не случайно: тогда один и тот же
        // проект выглядит одинаково на всех устройствах пользователя.
        let palette = ["#2F5BFF", "#14915B", "#D98200", "#7B3FFF", "#E5397F", "#0E9BAA"]
        let index = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count

        let project = Project(name: name, colorHex: palette[index])
        modelContext.insert(project)

        do {
            try modelContext.save()
        } catch {
            Log.data.error("Проект не сохранён: \(error.localizedDescription)")
        }
    }

    /// Русский счёт: одна запись, две записи, пять записей.
    static func recordsText(_ count: Int) -> String {
        guard count > 0 else { return "пока без записей" }

        let remainder10 = count % 10
        let remainder100 = count % 100

        if remainder10 == 1, remainder100 != 11 { return "\(count) запись" }
        if (2...4).contains(remainder10), !(12...14).contains(remainder100) { return "\(count) записи" }
        return "\(count) записей"
    }
}

extension Color {
    /// Цвет из строки вида «#2F5BFF».
    init(projectHex: String) {
        let cleaned = projectHex.hasPrefix("#") ? String(projectHex.dropFirst()) : projectHex
        let value = UInt32(cleaned, radix: 16) ?? 0x2F5BFF
        self.init(UIColor(hex: value))
    }
}
