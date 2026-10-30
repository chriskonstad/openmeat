import CookCore
import SwiftUI

struct TargetPickerView: View {
    let probe: CookProbe
    let unit: TemperatureUnit
    let onSave: (Temperature?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: Int

    init(probe: CookProbe, unit: TemperatureUnit, onSave: @escaping (Temperature?) -> Void) {
        self.probe = probe
        self.unit = unit
        self.onSave = onSave
        let initial = probe.target?.value(in: unit) ?? (unit == .fahrenheit ? 165 : 74)
        _value = State(initialValue: Int(initial.rounded()))
    }

    private var range: ClosedRange<Int> { unit == .fahrenheit ? 80...300 : 25...150 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { value = max(range.lowerBound, value - 1) } label: { Image(systemName: "minus.circle.fill") }
                            .accessibilityIdentifier(AccessibilityID.Target.decrement)
                        Spacer()
                        Text("\(value)\(unit.symbol)")
                            .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                            .accessibilityIdentifier(AccessibilityID.Target.value)
                        Spacer()
                        Button { value = min(range.upperBound, value + 1) } label: { Image(systemName: "plus.circle.fill") }
                            .accessibilityIdentifier(AccessibilityID.Target.increment)
                    }
                    .font(.largeTitle)
                    .buttonStyle(.borderless)
                    Picker("Target", selection: $value) {
                        ForEach(Array(range), id: \.self) { Text("\($0)\(unit.symbol)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .accessibilityIdentifier(AccessibilityID.Target.picker)
                }
                ForEach(Dictionary(grouping: TargetPreset.defaults, by: \.group).sorted(by: { $0.key < $1.key }), id: \.key) { group, presets in
                    Section(group) {
                        ForEach(presets) { preset in
                            Button {
                                value = Int(preset.target.value(in: unit).rounded())
                            } label: {
                                LabeledContent(preset.name, value: preset.target.formatted(unit))
                            }
                            .accessibilityIdentifier(AccessibilityID.Target.preset(preset.id))
                        }
                    }
                }
                if probe.target != nil {
                    Button("Clear target", role: .destructive) {
                        onSave(nil)
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.Target.clear)
                }
            }
            .navigationTitle(probe.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        onSave(Temperature(Double(value), unit))
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.Target.save)
                }
            }
        }
        .presentationDetents([.large])
    }
}
