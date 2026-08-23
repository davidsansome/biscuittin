import UIKit

/// Transient message for action results (DESIGN.md §15).
///
/// Used for partial failures and skipped items — cases where a blanket alert would be too
/// heavy but silence would be wrong. Never blocks interaction.
enum Toast {
    static func show(_ message: String, in view: UIView, duration: TimeInterval = 2.4) {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        container.layer.cornerRadius = 14
        container.layer.cornerCurve = .continuous
        container.alpha = 0
        container.isUserInteractionEnabled = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 0
        label.textAlignment = .center

        container.addSubview(label)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        UIView.animate(withDuration: 0.2) { container.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            UIView.animate(withDuration: 0.25) {
                container.alpha = 0
            } completion: { _ in
                container.removeFromSuperview()
            }
        }
    }

    /// Summarises an action outcome, or returns nil when everything succeeded silently.
    static func message(for outcome: ActionOutcome, verb: String) -> String? {
        var parts: [String] = []
        if outcome.failures.count == 1, let error = outcome.failures.first?.error {
            // With a single failure there is room to say *why*. "1 couldn't be rotated" tells
            // the user nothing and gives a bug report nothing to go on.
            parts.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        } else if !outcome.failures.isEmpty {
            parts.append("\(outcome.failures.count) couldn’t be \(verb)")
        }
        if !outcome.skippedUnsupported.isEmpty {
            let n = outcome.skippedUnsupported.count
            parts.append("\(n) \(n == 1 ? "item" : "items") can’t be rotated yet")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
