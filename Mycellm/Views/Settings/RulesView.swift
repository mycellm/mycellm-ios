import SwiftUI

/// Privacy Guard rules management — view, toggle, add, delete, and test rules.
struct RulesView: View {
    @State private var guard_ = SensitiveDataGuard()
    @State private var showAddSheet = false
    @State private var testText = ""

    private var categories: [String] {
        let cats = Set(guard_.rules.map(\.category))
        let order = ["API Keys", "Secrets", "Financial", "PII", "Custom"]
        return order.filter { cats.contains($0) } + cats.sorted().filter { !order.contains($0) }
    }

    var body: some View {
        List {
            // Test field
            testSection

            // Rules by category
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(guard_.rules.filter({ $0.category == category })) { rule in
                        RuleRow(rule: rule, guard_: guard_)
                    }
                    .onDelete { offsets in
                        let catRules = guard_.rules.filter { $0.category == category }
                        for offset in offsets {
                            let rule = catRules[offset]
                            if !rule.builtin {
                                guard_.removeCustomRule(id: rule.id)
                            }
                        }
                    }
                }
            }

            // Add button
            Section {
                Button {
                    showAddSheet = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.sporeGreen)
                        Text("Add Custom Rule")
                            .font(.mono(13))
                            .foregroundStyle(Color.consoleText)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.voidBlack)
        .navigationTitle("Privacy Rules")
        .font(.mono(13))
        .sheet(isPresented: $showAddSheet) {
            AddRuleSheet(guard_: guard_, isPresented: $showAddSheet)
        }
    }

    // MARK: - Test Section

    private var testSection: some View {
        Section(header: Text("Test"), footer: Text("Type text to see which rules match.").font(.mono(10))) {
            TextField("Paste text to test...", text: $testText, axis: .vertical)
                .font(.mono(12))
                .foregroundStyle(Color.consoleText)
                .lineLimit(3)

            if !testText.isEmpty {
                let result = guard_.scan(testText)
                if result.matches.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.sporeGreen)
                        Text("No sensitive data detected")
                            .font(.mono(11))
                            .foregroundStyle(Color.sporeGreen)
                    }
                } else {
                    ForEach(result.matches) { match in
                        HStack(spacing: 6) {
                            severityDot(match.rule.severity)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.rule.label)
                                    .font(.mono(11, weight: .medium))
                                    .foregroundStyle(Color.consoleText)
                                Text(match.matchedText)
                                    .font(.mono(10))
                                    .foregroundStyle(Color.consoleDim)
                            }
                        }
                    }
                }
            }
        }
    }

    private func severityDot(_ severity: SensitiveDataGuard.Severity) -> some View {
        Circle()
            .fill(severityColor(severity))
            .frame(width: 8, height: 8)
    }

    private func severityColor(_ severity: SensitiveDataGuard.Severity) -> Color {
        switch severity {
        case .high: Color.computeRed
        case .medium: Color.ledgerGold
        case .low: Color.consoleDim
        }
    }
}

// MARK: - Rule Row

private struct RuleRow: View {
    let rule: SensitiveDataGuard.Rule
    let guard_: SensitiveDataGuard

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { rule.enabled },
                set: { guard_.toggleRule(id: rule.id, enabled: $0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(rule.label)
                            .font(.mono(12, weight: .medium))
                            .foregroundStyle(rule.enabled ? Color.consoleText : Color.consoleDim)
                        severityBadge(rule.severity)
                    }
                    Text(rule.pattern)
                        .font(.mono(9))
                        .foregroundStyle(Color.consoleDim)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.switch)
        }
        .deleteDisabled(rule.builtin)
    }

    private func severityBadge(_ severity: SensitiveDataGuard.Severity) -> some View {
        Text(severity.rawValue.uppercased())
            .font(.mono(8, weight: .semibold))
            .foregroundStyle(badgeColor(severity))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(badgeColor(severity).opacity(0.15))
            .clipShape(Capsule())
    }

    private func badgeColor(_ severity: SensitiveDataGuard.Severity) -> Color {
        switch severity {
        case .high: Color.computeRed
        case .medium: Color.ledgerGold
        case .low: Color.consoleDim
        }
    }
}

// MARK: - Add Rule Sheet

private struct AddRuleSheet: View {
    let guard_: SensitiveDataGuard
    @Binding var isPresented: Bool
    @State private var label = ""
    @State private var pattern = ""
    @State private var severity: SensitiveDataGuard.Severity = .high
    @State private var category = "Custom"

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule Details") {
                    TextField("Label", text: $label)
                        .font(.mono(13))
                    TextField("Regex Pattern", text: $pattern)
                        .font(.mono(12))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Severity", selection: $severity) {
                        Text("High").tag(SensitiveDataGuard.Severity.high)
                        Text("Medium").tag(SensitiveDataGuard.Severity.medium)
                        Text("Low").tag(SensitiveDataGuard.Severity.low)
                    }
                    .font(.mono(13))
                    TextField("Category", text: $category)
                        .font(.mono(13))
                }

                if !pattern.isEmpty {
                    Section("Pattern Preview") {
                        if (try? NSRegularExpression(pattern: pattern)) != nil {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.sporeGreen)
                                Text("Valid regex")
                                    .font(.mono(11))
                                    .foregroundStyle(Color.sporeGreen)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.computeRed)
                                Text("Invalid regex")
                                    .font(.mono(11))
                                    .foregroundStyle(Color.computeRed)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.voidBlack)
            .navigationTitle("Add Rule")
            .navigationBarTitleDisplayMode(.inline)
            .font(.mono(13))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .font(.mono(13))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard_.addCustomRule(label: label, pattern: pattern, severity: severity, category: category)
                        isPresented = false
                    }
                    .font(.mono(13))
                    .disabled(label.isEmpty || pattern.isEmpty || (try? NSRegularExpression(pattern: pattern)) == nil)
                }
            }
        }
    }
}
