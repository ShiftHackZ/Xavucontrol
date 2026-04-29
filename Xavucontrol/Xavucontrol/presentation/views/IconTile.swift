import SwiftUI

struct IconTile: View {
    let systemName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 40, height: 40)
    }
}
