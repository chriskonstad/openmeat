import Foundation

public struct TargetPreset: Hashable, Sendable, Identifiable, Codable {
    public var id: String { "\(group)/\(name)" }
    public var group: String
    public var name: String
    public var target: Temperature

    public init(group: String, name: String, fahrenheit: Double) {
        self.group = group
        self.name = name
        self.target = Temperature(fahrenheit: fahrenheit)
    }

    public static let defaults: [TargetPreset] = [
        .init(group: "Beef", name: "Rare", fahrenheit: 125),
        .init(group: "Beef", name: "Medium rare", fahrenheit: 130),
        .init(group: "Beef", name: "Medium", fahrenheit: 140),
        .init(group: "Beef", name: "Brisket", fahrenheit: 203),
        .init(group: "Pork", name: "Chops / tenderloin", fahrenheit: 145),
        .init(group: "Pork", name: "Pulled pork", fahrenheit: 203),
        .init(group: "Pork", name: "Ribs", fahrenheit: 198),
        .init(group: "Poultry", name: "Breast", fahrenheit: 160),
        .init(group: "Poultry", name: "Thigh", fahrenheit: 175),
        .init(group: "Fish", name: "Salmon", fahrenheit: 125),
    ]
}

public enum QuickNotes {
    public static let defaults = ["Wrapped", "Spritzed", "Added wood", "Added fuel", "Lid opened", "Flipped", "Rested"]
}
