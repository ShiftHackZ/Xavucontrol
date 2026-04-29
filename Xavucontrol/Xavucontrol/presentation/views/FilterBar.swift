import SwiftUI

struct FilterBar<Selection: Hashable & CaseIterable & Identifiable & RawRepresentable>: View where Selection.RawValue == String {
    @Binding var selection: Selection

    var body: some View {
        HStack(spacing: 8) {
            Text("Show:")
            Picker("", selection: $selection) {
                ForEach(Array(Selection.allCases)) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            Spacer()
        }
        .controlSize(.small)
    }
}
