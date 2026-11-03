import SwiftUI

/// Dark, bold, gradient look. Colors keep white text at 4.5:1 contrast or better.
enum Theme {
    static let purple = Color(red: 0.42, green: 0.24, blue: 0.94)
    static let pink = Color(red: 0.76, green: 0.11, blue: 0.45)
    static let blue = Color(red: 0.0, green: 0.62, blue: 1.0)
    static let green = Color(red: 0.0, green: 0.86, blue: 0.52)
    static let yellow = Color(red: 1.0, green: 0.85, blue: 0.2)

    static let background = Color.black
    static let surface = Color(white: 0.14)
    static let secondaryText = Color(white: 0.7)

    static let gradient = LinearGradient(colors: [purple, pink], startPoint: .leading, endPoint: .trailing)
    static let rainbow = LinearGradient(
        colors: [green, blue, purple, pink, yellow], startPoint: .leading, endPoint: .trailing
    )
}

/// Thin rainbow stripe used as a divider.
struct RainbowStripe: View {
    var body: some View {
        Theme.rainbow.frame(height: 3).accessibilityHidden(true)
    }
}

/// Big pill button: gradient when prominent, dark grey otherwise.
struct PillButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(minHeight: 52)
                .background(
                    prominent ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.surface),
                    in: Capsule()
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Capsule())
        }
    }
}

/// Small dark rounded button for icons and short words; at least 44 × 44 points.
struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minWidth: 48, minHeight: 44)
                .background(
                    selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.surface),
                    in: Capsule()
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
                .contentShape(Capsule())
        }
    }
}

/// A row of chips where one is selected (replaces the small segmented controls).
struct ChipPicker<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                Button {
                    selection = option.value
                } label: {
                    Text(option.label).frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle(selected: selection == option.value))
                .accessibilityLabel("\(title) \(option.label)")
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
    }
}
