import SwiftUI

// MARK: - Calculator Model
enum CalcButton: String, CaseIterable {
    case clear = "C", sign = "±", percent = "%", divide = "÷"
    case seven = "7", eight = "8", nine = "9", multiply = "×"
    case four = "4", five = "5", six = "6", subtract = "−"
    case one = "1", two = "2", three = "3", add = "+"
    case zero = "0", decimal = ".", equals = "="

    var isOperator: Bool {
        [.divide, .multiply, .subtract, .add, .equals].contains(self)
    }

    var isUtility: Bool {
        [.clear, .sign, .percent].contains(self)
    }
}

class CalculatorModel: ObservableObject {
    @Published var display = "0"

    private var currentValue: Double = 0
    private var pendingOperation: CalcButton? = nil
    private var isTyping = false
    private var justEvaluated = false

    func press(_ button: CalcButton) {
        switch button {
        case .clear:
            display = "0"
            currentValue = 0
            pendingOperation = nil
            isTyping = false
            justEvaluated = false

        case .sign:
            if let value = Double(display), value != 0 {
                display = formatNumber(-value)
            }

        case .percent:
            if let value = Double(display) {
                display = formatNumber(value / 100)
            }

        case .divide, .multiply, .subtract, .add:
            if let value = Double(display) {
                if let op = pendingOperation {
                    currentValue = compute(op, currentValue, value)
                    display = formatNumber(currentValue)
                } else {
                    currentValue = value
                }
                pendingOperation = button
                isTyping = false
                justEvaluated = false
            }

        case .equals:
            if let op = pendingOperation, let value = Double(display) {
                display = formatNumber(compute(op, currentValue, value))
                currentValue = 0
                pendingOperation = nil
                isTyping = false
                justEvaluated = true
            }

        case .decimal:
            if justEvaluated {
                display = "0."
                isTyping = true
                justEvaluated = false
            } else if !display.contains(".") {
                display += "."
                isTyping = true
            }

        default:
            if justEvaluated {
                display = button.rawValue
                isTyping = true
                justEvaluated = false
            } else if isTyping {
                display += button.rawValue
            } else {
                display = button.rawValue
                isTyping = true
            }
        }
    }

    private func compute(_ op: CalcButton, _ a: Double, _ b: Double) -> Double {
        switch op {
        case .add:      return a + b
        case .subtract: return a - b
        case .multiply: return a * b
        case .divide:   return b != 0 ? a / b : Double.infinity
        default:        return b
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value.isInfinite || value.isNaN { return "错误" }
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Calculator Views
struct CalculatorTab: View {
    @EnvironmentObject var model: CalculatorModel

    let buttons: [[CalcButton]] = [
        [.clear, .sign, .percent, .divide],
        [.seven, .eight, .nine, .multiply],
        [.four, .five, .six, .subtract],
        [.one, .two, .three, .add],
        [.zero, .decimal, .equals]
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Text(model.display)
                    .font(.system(size: 44, weight: .light, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 20)
            }
            .frame(height: 70)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, 16)

            ForEach(buttons, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { button in
                        CalcButtonView(button: button) {
                            model.press(button)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 16)
        .frame(width: 320)
    }
}

struct CalcButtonView: View {
    let button: CalcButton
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if button == .zero {
                Text(button.rawValue)
                    .font(.system(size: 26, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(buttonColor)
                    )
            } else {
                Text(button.rawValue)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: button == .equals ? nil : 50,
                           height: 50)
                    .frame(maxWidth: button == .equals ? .infinity : nil)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(buttonColor)
                    )
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(buttonForegroundColor)
    }

    var buttonColor: Color {
        if button.isOperator {
            return .orange
        } else if button.isUtility {
            return Color.primary.opacity(0.12)
        } else {
            return Color.primary.opacity(0.08)
        }
    }

    var buttonForegroundColor: Color {
        button.isOperator ? .white : .primary
    }
}
