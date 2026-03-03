import SwiftUI

struct FilterChip: View {
    let label: String
    var icon: String? = nil
    let isActive: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? color.opacity(0.2) : Color.clear)
            .foregroundStyle(isActive ? color : .secondary)
            .overlay {
                Capsule()
                    .strokeBorder(isActive ? color.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
