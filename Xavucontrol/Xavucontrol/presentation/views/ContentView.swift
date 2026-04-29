//
//  ContentView.swift
//  Xavucontrol
//
//  Created by ShiftHackZ on 28.04.2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        MainWindow()
            .environmentObject(AudioModel())
            .frame(minWidth: 860, minHeight: 560)
    }
}

#Preview {
    ContentView()
}
