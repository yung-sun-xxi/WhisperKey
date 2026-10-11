import SwiftUI

// The controls the Settings window is built from (#162), shared with the other windows of
// #105. Each one reads `tokens.controls`: `.system` renders exactly the system control the
// app used before (Classic), `.drawn` draws it from the tokens (Midnight). The label each
// takes is for VoiceOver; the row beside the control shows the visible one.

// MARK: - Toggle

/// A switch. Drawn: a `sizes.toggle` track, brand when on with an `onBrand` knob,
/// `raisedControl` when off with an `offKnob` knob.
public struct ThemedToggle: View {
    @Environment(\.themeTokens) private var tokens
    private let label: String
    @Binding private var isOn: Bool

    public init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    public var body: some View {
        switch tokens.controls {
        case .system:
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(height: tokens.sizes.control)
        case .drawn:
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(DrawnSwitchStyle(tokens: tokens))
        }
    }
}

private struct DrawnSwitchStyle: ToggleStyle {
    let tokens: ThemeTokens

    func makeBody(configuration: Configuration) -> some View {
        DrawnSwitch(configuration: configuration, tokens: tokens)
    }
}

private struct DrawnSwitch: View {
    let configuration: ToggleStyleConfiguration
    let tokens: ThemeTokens

    private var isOn: Bool { configuration.isOn }
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let colors = tokens.colors
        let metrics = tokens.controlMetrics
        let track = RoundedRectangle(cornerRadius: tokens.radii.toggle, style: .continuous)
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                track
                    .fill(trackFill.color)
                    .overlay {
                        if !isEnabled {
                            track.strokeBorder(colors.edge.color, lineWidth: metrics.edgeWidth)
                        }
                    }
                Circle()
                    .fill((isOn && isEnabled ? colors.onBrand : colors.offKnob).color)
                    .frame(width: metrics.toggleKnob, height: metrics.toggleKnob)
                    .padding(metrics.toggleKnobInset)
            }
            .frame(width: tokens.sizes.toggle.width, height: tokens.sizes.toggle.height)
            .frame(height: tokens.sizes.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    /// The sheet's disabled control has no fill and a 05 edge.
    private var trackFill: ThemeColor {
        guard isEnabled else { return .system(.clear) }
        return isOn ? tokens.colors.brand : tokens.colors.raisedControl
    }
}

// MARK: - Push button

/// A push button. Drawn: `sizes.control` tall, `card` with an `edge` outline, the title in
/// `body`. A destructive one takes `destructiveText`: red in Classic, like its
/// neighbours in Midnight (#105 rule 2).
public struct ThemedPushButton: View {
    @Environment(\.themeTokens) private var tokens
    private let title: String
    private let role: ButtonRole?
    private let action: () -> Void

    public init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    public var body: some View {
        switch tokens.controls {
        case .system:
            if role == .destructive {
                Button(title, role: role, action: action)
                    .buttonStyle(.bordered)
                    .foregroundStyle(tokens.colors.destructiveText.color)
                    .controlSize(.small)
            } else {
                Button(title, role: role, action: action)
                    .controlSize(.small)
            }
        case .drawn:
            Button(title, role: role, action: action)
                .buttonStyle(DrawnPushButtonStyle(
                    tokens: tokens,
                    label: role == .destructive ? tokens.colors.destructiveText : tokens.colors.primaryText
                ))
        }
    }
}

private struct DrawnPushButtonStyle: ButtonStyle {
    let tokens: ThemeTokens
    let label: ThemeColor

    func makeBody(configuration: Configuration) -> some View {
        DrawnPushButton(configuration: configuration, tokens: tokens, label: label)
    }
}

private struct DrawnPushButton: View {
    let configuration: ButtonStyleConfiguration
    let tokens: ThemeTokens
    let label: ThemeColor
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let colors = tokens.colors
        configuration.label
            .font(tokens.type.body.font)
            .foregroundStyle((isEnabled ? label : colors.secondaryText).color)
            .lineLimit(1)
            .padding(.horizontal, tokens.controlMetrics.horizontalPadding)
            .frame(height: tokens.sizes.control)
            .drawnControlBox(tokens, fill: isEnabled ? (configuration.isPressed ? colors.raisedControl : colors.card) : nil)
            .contentShape(Rectangle())
    }
}

// MARK: - Segmented control

/// A choice of a few options side by side. Drawn: a `card` track `segmentedWidth` wide,
/// the active segment brand with its label in `labelOnBrand` / `onBrand`.
public struct ThemedSegmentedPicker<Value: Hashable>: View {
    @Environment(\.themeTokens) private var tokens
    @Environment(\.isEnabled) private var isEnabled
    private let label: String
    @Binding private var selection: Value
    private let options: [Value]
    private let title: (Value) -> String

    public init(_ label: String, selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self.label = label
        _selection = selection
        self.options = options
        self.title = title
    }

    public var body: some View {
        switch tokens.controls {
        case .system:
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: tokens.controlMetrics.segmentedWidth)
            .frame(height: tokens.sizes.control)
        case .drawn:
            drawn
        }
    }

    private var drawn: some View {
        let metrics = tokens.controlMetrics
        let colors = tokens.colors
        let track = RoundedRectangle(cornerRadius: tokens.radii.control, style: .continuous)
        return HStack(spacing: metrics.segmentGap) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font((isSelected ? tokens.type.labelOnBrand : tokens.type.small).font)
                        .foregroundStyle(segmentText(isSelected: isSelected).color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: tokens.sizes.modeSegment)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: tokens.radii.modeSegment, style: .continuous)
                                    .fill((isEnabled ? colors.brand : colors.raisedControl).color)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(metrics.trackPadding)
        .frame(width: metrics.segmentedWidth)
        .background((isEnabled ? colors.card : ThemeColor.system(.clear)).color, in: track)
        .overlay {
            if !isEnabled {
                track.strokeBorder(colors.edge.color, lineWidth: metrics.edgeWidth)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segmentText(isSelected: Bool) -> ThemeColor {
        guard isEnabled else { return tokens.colors.secondaryText }
        return isSelected ? tokens.colors.onBrand : tokens.colors.navigationText
    }
}

// MARK: - Pop-up

/// A pop-up menu of options. Drawn: a `card` box at least `popUpMinWidth` wide, the title in
/// `body`, up and down chevrons in `secondaryText`; the menu that opens is the system's.
public struct ThemedPopUpPicker<Value: Hashable>: View {
    @Environment(\.themeTokens) private var tokens
    private let label: String
    @Binding private var selection: Value
    private let options: [Value]
    private let title: (Value) -> String

    public init(_ label: String, selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self.label = label
        _selection = selection
        self.options = options
        self.title = title
    }

    public var body: some View {
        switch tokens.controls {
        case .system:
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(height: tokens.sizes.control)
        case .drawn:
            DrawnPopUpButton(
                titles: options.map(title),
                selectedIndex: Binding(
                    get: { options.firstIndex(of: selection) ?? 0 },
                    set: { index in
                        guard options.indices.contains(index) else { return }
                        selection = options[index]
                    }
                ),
                tokens: tokens
            )
            .fixedSize()
            .accessibilityLabel(label)
        }
    }
}

// MARK: - Number field

/// A whole number with a stepper and its unit. System: a rounded field, the system
/// stepper, then the unit. Drawn: a `card` box holding the number and its unit, then a
/// drawn stepper that repeats while held.
public struct ThemedNumberField: View {
    @Environment(\.themeTokens) private var tokens
    private let label: String
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let step: Int
    private let unit: String

    public init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int, unit: String) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    public var body: some View {
        let metrics = tokens.controlMetrics
        switch tokens.controls {
        case .system:
            HStack(spacing: metrics.numberUnitGap) {
                TextField("", value: $value, format: .number)
                    .accessibilityLabel(label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: metrics.numberFieldWidth)
                    .controlSize(.small)
                    .frame(height: tokens.sizes.control)
                Stepper(label, value: $value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(height: tokens.sizes.control)
                unitText
                    .frame(height: tokens.sizes.control)
            }
            .frame(height: tokens.sizes.control)
        case .drawn:
            HStack(spacing: metrics.stepperGap) {
                HStack(spacing: metrics.numberUnitGap) {
                    TextField("", value: $value, format: .number)
                        .accessibilityLabel(label)
                        .textFieldStyle(.plain)
                        .font(tabularBody.font)
                        .foregroundStyle(tokens.colors.primaryText.color)
                        .frame(width: metrics.numberFieldWidth)
                    unitText
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .frame(height: tokens.sizes.control)
                .drawnControlBox(tokens, fill: tokens.colors.card)
                DrawnStepper(value: $value, range: range, step: step, tokens: tokens, accessibilityLabel: label)
                    .frame(width: metrics.stepper.width, height: metrics.stepper.height)
            }
        }
    }

    private var unitText: some View {
        Text(unit)
            .font(tokens.type.fieldCaption.font)
            .foregroundStyle(tokens.colors.secondaryText.color)
    }

    private var tabularBody: ThemeFont {
        var font = tokens.type.body
        font.tabularDigits = true
        return font
    }
}

// MARK: - Secure field

/// A password-style text field `secureFieldWidth` wide. Drawn: a `card` box with an
/// `edge` outline. `focus` is the field's own focus state, for the view that owns it.
public struct ThemedSecureField: View {
    @Environment(\.themeTokens) private var tokens
    private let placeholder: String
    @Binding private var text: String
    private let focus: FocusState<Bool>.Binding

    public init(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding) {
        self.placeholder = placeholder
        _text = text
        self.focus = focus
    }

    public var body: some View {
        let metrics = tokens.controlMetrics
        switch tokens.controls {
        case .system:
            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: metrics.secureFieldWidth)
                .controlSize(.small)
                .frame(height: tokens.sizes.control)
                .focused(focus)
        case .drawn:
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(tokens.type.body.font)
                .foregroundStyle(tokens.colors.primaryText.color)
                .focused(focus)
                .padding(.horizontal, metrics.horizontalPadding)
                .frame(width: metrics.secureFieldWidth, height: tokens.sizes.control)
                .drawnControlBox(tokens, fill: tokens.colors.card)
        }
    }
}

// MARK: - Shared box

extension View {
    /// The box every drawn control sits in: `fill` (none for a disabled control), an
    /// `edge` outline, `radii.control`.
    func drawnControlBox(_ tokens: ThemeTokens, fill: ThemeColor?) -> some View {
        let box = RoundedRectangle(cornerRadius: tokens.radii.control, style: .continuous)
        return background((fill ?? .system(.clear)).color, in: box)
            .overlay(box.strokeBorder(tokens.colors.edge.color, lineWidth: tokens.controlMetrics.edgeWidth))
    }
}
