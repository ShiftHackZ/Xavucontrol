import AppKit
import SwiftUI

struct PatchbayTab: View {
    @EnvironmentObject private var audioModel: AudioModel

    private var graph: PatchbayGraph {
        PatchbayGraphBuilder(audioModel: audioModel).makeGraph()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DiscoveryBar()
            StreamDiscoveryBar()

            if graph.nodes.isEmpty {
                EmptyState(title: "No audio devices", detail: audioModel.deviceDiscoveryStatus)
            } else {
                PatchbayGraphView(graph: graph)
            }
        }
    }
}

private struct PatchbayGraphBuilder {
    let audioModel: AudioModel

    func makeGraph() -> PatchbayGraph {
        let playbackStreams = audioModel.streams
            .filter { $0.direction == .playback && !$0.isVirtualStream }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        let recordingStreams = audioModel.streams
            .filter { $0.direction == .recording && !$0.isVirtualStream }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }

        var nodesByID: [PatchbayNode.ID: PatchbayNode] = [:]
        var links: [PatchbayLink] = []
        let virtualMicNode = virtualMicMixerNode()

        let visibleInputDevices = audioModel.inputDevices
            .filter { shouldShowDeviceNode($0) }
            .sorted(by: deviceSort)
        let visibleOutputDevices = audioModel.outputDevices
            .filter { shouldShowDeviceNode($0) }
            .sorted(by: deviceSort)

        for device in visibleInputDevices {
            let node = inputDeviceNode(device: device)
            nodesByID[node.id] = node
        }

        for device in visibleOutputDevices {
            let node = outputDeviceNode(device: device)
            nodesByID[node.id] = node
        }

        nodesByID[virtualMicNode.id] = virtualMicNode

        for device in visibleInputDevices where audioModel.isInputDeviceIncludedInVirtualMic(deviceID: device.id) {
            let sourceNodeID = inputNodeID(device.id)
            if nodesByID[sourceNodeID] != nil, nodesByID[virtualMicNode.id] != nil {
                links.append(contentsOf: stereoLinks(
                    sourceNodeID: sourceNodeID,
                    sourcePrefix: "capture",
                    targetNodeID: virtualMicNode.id,
                    targetPrefix: "mix",
                    kind: .virtualMic
                ))
            }
        }

        for device in visibleInputDevices {
            guard let outputDeviceID = audioModel.inputMonitorOutputDeviceID(for: device.id) else {
                continue
            }

            let sourceNodeID = inputNodeID(device.id)
            let targetNodeID = outputNodeID(outputDeviceID)
            if nodesByID[sourceNodeID] != nil, nodesByID[targetNodeID] != nil {
                links.append(contentsOf: stereoLinks(
                    sourceNodeID: sourceNodeID,
                    sourcePrefix: "capture",
                    targetNodeID: targetNodeID,
                    targetPrefix: "playback",
                    kind: .monitor
                ))
            }
        }

        for stream in playbackStreams {
            let appNode = appNode(stream: stream, direction: .playback, side: .left)
            let targetNodeID = playbackTargetNodeID(stream: stream)

            nodesByID[appNode.id] = appNode
            if nodesByID[targetNodeID] != nil {
                links.append(contentsOf: stereoLinks(
                    sourceNodeID: appNode.id,
                    sourcePrefix: "out",
                    targetNodeID: targetNodeID,
                    targetPrefix: "playback",
                    kind: .playback
                ))
            }

            if audioModel.isPlaybackStreamIncludedInVirtualMic(stream), nodesByID[virtualMicNode.id] != nil {
                links.append(contentsOf: stereoLinks(
                    sourceNodeID: appNode.id,
                    sourcePrefix: "out",
                    targetNodeID: virtualMicNode.id,
                    targetPrefix: "mix",
                    kind: .virtualMic
                ))
            }
        }

        for stream in recordingStreams {
            let appNode = appNode(stream: stream, direction: .recording, side: .right)
            let sourceNodeID = recordingSourceNodeID(stream: stream)

            nodesByID[appNode.id] = appNode
            if nodesByID[sourceNodeID] != nil {
                links.append(contentsOf: stereoLinks(
                    sourceNodeID: sourceNodeID,
                    sourcePrefix: "capture",
                    targetNodeID: appNode.id,
                    targetPrefix: "in",
                    kind: .recording
                ))
            }
        }

        return PatchbayGraph(nodes: order(nodes: Array(nodesByID.values)), links: links)
    }

    private func inputDeviceNode(device: AudioDevice) -> PatchbayNode {
        PatchbayNode(
            id: inputNodeID(device.id),
            title: device.name,
            subtitle: deviceSubtitle(device: device, fallback: "Input device"),
            systemImage: device.iconName,
            stream: nil,
            kind: .input,
            side: .left,
            ports: stereoPorts(prefix: "capture", side: .trailing, kind: .input)
        )
    }

    private func outputDeviceNode(device: AudioDevice) -> PatchbayNode {
        PatchbayNode(
            id: outputNodeID(device.id),
            title: device.name,
            subtitle: deviceSubtitle(device: device, fallback: "Output device"),
            systemImage: device.iconName,
            stream: nil,
            kind: .output,
            side: .right,
            ports: stereoPorts(prefix: "playback", side: .leading, kind: .output)
        )
    }

    private func virtualMicMixerNode() -> PatchbayNode {
        PatchbayNode(
            id: virtualMicMixerNodeID,
            title: SetupState.virtualMicName,
            subtitle: "Virtual microphone mixer",
            systemImage: "dial.low",
            stream: nil,
            kind: .mixer,
            side: .center,
            ports: [
                PatchbayPort(id: "mix-FL", title: "mix_FL", side: .leading, kind: .mixer),
                PatchbayPort(id: "mix-FR", title: "mix_FR", side: .leading, kind: .mixer),
                PatchbayPort(id: "capture-FL", title: "capture_FL", side: .trailing, kind: .mixer),
                PatchbayPort(id: "capture-FR", title: "capture_FR", side: .trailing, kind: .mixer)
            ]
        )
    }

    private func appNode(stream: AppAudioStream, direction: StreamDirection, side: PatchbaySide) -> PatchbayNode {
        let prefix = direction == .playback ? "out" : "in"
        return PatchbayNode(
            id: "\(direction.rawValue)-app-\(stream.id)",
            title: stream.appName,
            subtitle: stream.detail,
            systemImage: stream.iconName,
            stream: stream,
            kind: .application,
            side: side,
            ports: stereoPorts(prefix: prefix, side: side == .left ? .trailing : .leading, kind: .application)
        )
    }

    private func playbackTargetNodeID(stream: AppAudioStream) -> PatchbayNode.ID {
        let routeSelectionID = audioModel.routeSelectionID(for: stream)
        if routeSelectionID == AppPreferences.defaultOutputRouteID {
            return outputNodeID(applicationDefaultOutputDeviceID() ?? routeSelectionID)
        }
        return outputNodeID(stream.requestedDeviceID ?? routeSelectionID)
    }

    private func recordingSourceNodeID(stream: AppAudioStream) -> PatchbayNode.ID {
        if audioModel.streamUsesXavucontrolVirtualDevice(stream) {
            return virtualMicMixerNodeID
        }

        let routeSelectionID = audioModel.routeSelectionID(for: stream)
        if routeSelectionID == AppPreferences.defaultInputRouteID {
            return inputNodeID(applicationDefaultInputDeviceID() ?? routeSelectionID)
        }
        return inputNodeID(stream.requestedDeviceID ?? routeSelectionID)
    }

    private func applicationDefaultOutputDeviceID() -> AudioDevice.ID? {
        let name = audioModel.applicationDefaultOutputDeviceName()
        return audioModel.outputDevices.first(where: { $0.name == name })?.id
    }

    private func applicationDefaultInputDeviceID() -> AudioDevice.ID? {
        let name = audioModel.applicationDefaultInputDeviceName()
        return audioModel.inputDevices.first(where: { $0.name == name })?.id
    }

    private func deviceSubtitle(device: AudioDevice, fallback: String) -> String {
        if device.isDefault {
            return "\(fallback) / system default"
        }
        if device.isXavucontrolVirtualDevice {
            return "\(fallback) / virtual"
        }
        return fallback
    }

    private func stereoPorts(prefix: String, side: PatchbayPortSide, kind: PatchbayNodeKind) -> [PatchbayPort] {
        [
            PatchbayPort(id: "\(prefix)-FL", title: "\(prefix)_FL", side: side, kind: kind),
            PatchbayPort(id: "\(prefix)-FR", title: "\(prefix)_FR", side: side, kind: kind)
        ]
    }

    private func stereoLinks(
        sourceNodeID: PatchbayNode.ID,
        sourcePrefix: String,
        targetNodeID: PatchbayNode.ID,
        targetPrefix: String,
        kind: PatchbayLinkKind
    ) -> [PatchbayLink] {
        [
            PatchbayLink(
                id: "\(sourceNodeID)-\(targetNodeID)-FL",
                sourceNodeID: sourceNodeID,
                sourcePortID: "\(sourcePrefix)-FL",
                targetNodeID: targetNodeID,
                targetPortID: "\(targetPrefix)-FL",
                kind: kind
            ),
            PatchbayLink(
                id: "\(sourceNodeID)-\(targetNodeID)-FR",
                sourceNodeID: sourceNodeID,
                sourcePortID: "\(sourcePrefix)-FR",
                targetNodeID: targetNodeID,
                targetPortID: "\(targetPrefix)-FR",
                kind: kind
            )
        ]
    }

    private func inputNodeID(_ deviceID: AudioDevice.ID) -> PatchbayNode.ID {
        "input-\(deviceID)"
    }

    private func outputNodeID(_ deviceID: AudioDevice.ID) -> PatchbayNode.ID {
        "output-\(deviceID)"
    }

    private var virtualMicMixerNodeID: PatchbayNode.ID {
        "virtual-mic-mixer"
    }

    private func deviceSort(_ lhs: AudioDevice, _ rhs: AudioDevice) -> Bool {
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault
        }
        if lhs.isXavucontrolVirtualDevice != rhs.isXavucontrolVirtualDevice {
            return lhs.isXavucontrolVirtualDevice
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func shouldShowDeviceNode(_ device: AudioDevice) -> Bool {
        !device.isXavucontrolVirtualDevice
    }

    private func order(nodes: [PatchbayNode]) -> [PatchbayNode] {
        nodes.sorted { lhs, rhs in
            if lhs.side != rhs.side {
                return lhs.side.sortOrder < rhs.side.sortOrder
            }
            if lhs.kind.sortOrder != rhs.kind.sortOrder {
                return lhs.kind.sortOrder < rhs.kind.sortOrder
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

private struct PatchbayGraph {
    let nodes: [PatchbayNode]
    let links: [PatchbayLink]

    var signature: String {
        nodes.map(\.id).joined(separator: "|")
    }
}

private struct PatchbayNode: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let stream: AppAudioStream?
    let kind: PatchbayNodeKind
    let side: PatchbaySide
    let ports: [PatchbayPort]
}

private struct PatchbayPort: Identifiable {
    let id: String
    let title: String
    let side: PatchbayPortSide
    let kind: PatchbayNodeKind
}

private struct PatchbayLink: Identifiable {
    let id: String
    let sourceNodeID: PatchbayNode.ID
    let sourcePortID: PatchbayPort.ID
    let targetNodeID: PatchbayNode.ID
    let targetPortID: PatchbayPort.ID
    let kind: PatchbayLinkKind
}

private enum PatchbaySide {
    case left
    case center
    case right

    var sortOrder: Int {
        switch self {
        case .left: 0
        case .center: 1
        case .right: 2
        }
    }
}

private enum PatchbayPortSide {
    case leading
    case trailing
}

private enum PatchbayNodeKind {
    case input
    case application
    case mixer
    case output

    var sortOrder: Int {
        switch self {
        case .input: 0
        case .application: 1
        case .mixer: 2
        case .output: 3
        }
    }

    var tint: Color {
        switch self {
        case .input: .yellow
        case .application: .blue
        case .mixer: .teal
        case .output: .indigo
        }
    }
}

private enum PatchbayLinkKind {
    case playback
    case recording
    case virtualMic
    case monitor

    var color: Color {
        switch self {
        case .playback: .blue
        case .recording: .yellow
        case .virtualMic: .teal
        case .monitor: .green
        }
    }
}

private struct PatchbayGraphView: View {
    private static let defaultZoom: CGFloat = 0.8
    private static let minimumZoom: CGFloat = 0.5
    private static let maximumZoom: CGFloat = 1.8

    let graph: PatchbayGraph

    @State private var zoom: CGFloat = Self.defaultZoom
    @State private var nodeOrigins: [PatchbayNode.ID: CGPoint] = [:]
    @State private var dragStartOrigins: [PatchbayNode.ID: CGPoint] = [:]
    @State private var pinchStartZoom: CGFloat?

    private var baseLayout: PatchbayLayout {
        PatchbayLayout(graph: graph)
    }

    private var layout: PatchbayLayout {
        PatchbayLayout(graph: graph, overrides: nodeOrigins)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Spacer()

                Button {
                    zoom = max(Self.minimumZoom, zoom - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")

                Text("\(Int(zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44)

                Button {
                    zoom = min(Self.maximumZoom, zoom + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        zoom = Self.defaultZoom
                        nodeOrigins = baseLayout.defaultOrigins
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset view")
            }

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    PatchbayGrid()
                        .frame(width: proxy.size.width, height: proxy.size.height)

                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Canvas { context, _ in
                                for link in graph.links {
                                    guard let source = layout.portPoint(nodeID: link.sourceNodeID, portID: link.sourcePortID),
                                          let target = layout.portPoint(nodeID: link.targetNodeID, portID: link.targetPortID) else {
                                        continue
                                    }

                                    var path = Path()
                                    path.move(to: source)
                                    let distance = max(120, abs(target.x - source.x) * 0.46)
                                    path.addCurve(
                                        to: target,
                                        control1: CGPoint(x: source.x + distance, y: source.y),
                                        control2: CGPoint(x: target.x - distance, y: target.y)
                                    )
                                    context.stroke(path, with: .color(link.kind.color.opacity(0.62)), lineWidth: 2)
                                }
                            }
                            .frame(width: layout.width, height: layout.height)

                            ForEach(graph.nodes) { node in
                                PatchbayNodeView(node: node)
                                    .frame(width: PatchbayLayout.nodeWidth, height: layout.nodeHeight(node))
                                    .position(layout.nodeCenter(node.id))
                                    .gesture(dragGesture(for: node))
                            }
                        }
                        .frame(width: layout.width, height: layout.height)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: layout.width * zoom, height: layout.height * zoom, alignment: .topLeading)
                    }
                }
            }
            .frame(minHeight: 520)
            .simultaneousGesture(pinchGesture)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.8), lineWidth: 1)
            }
        }
        .onAppear {
            syncNodeOrigins()
        }
        .onChange(of: graph.signature) {
            syncNodeOrigins()
        }
    }

    private func dragGesture(for node: PatchbayNode) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartOrigins[node.id] == nil {
                    dragStartOrigins[node.id] = nodeOrigins[node.id] ?? baseLayout.nodeOrigin(node.id)
                }

                guard let start = dragStartOrigins[node.id] else {
                    return
                }

                nodeOrigins[node.id] = CGPoint(
                    x: max(12, start.x + value.translation.width / zoom),
                    y: max(12, start.y + value.translation.height / zoom)
                )
            }
            .onEnded { _ in
                dragStartOrigins[node.id] = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                if pinchStartZoom == nil {
                    pinchStartZoom = zoom
                }

                let startZoom = pinchStartZoom ?? zoom
                zoom = min(Self.maximumZoom, max(Self.minimumZoom, startZoom * magnification))
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    private func syncNodeOrigins() {
        let defaults = baseLayout.defaultOrigins
        var updated: [PatchbayNode.ID: CGPoint] = [:]
        var occupiedFrames: [CGRect] = []

        for node in graph.nodes {
            guard let existingOrigin = nodeOrigins[node.id] else {
                continue
            }

            updated[node.id] = existingOrigin
            occupiedFrames.append(frame(for: node, origin: existingOrigin))
        }

        for node in graph.nodes where updated[node.id] == nil {
            let defaultOrigin = defaults[node.id] ?? .zero
            let origin = firstAvailableOrigin(for: node, from: defaultOrigin, occupiedFrames: occupiedFrames)
            updated[node.id] = origin
            occupiedFrames.append(frame(for: node, origin: origin))
        }

        nodeOrigins = updated
    }

    private func firstAvailableOrigin(
        for node: PatchbayNode,
        from defaultOrigin: CGPoint,
        occupiedFrames: [CGRect]
    ) -> CGPoint {
        var origin = defaultOrigin
        var candidateFrame = frame(for: node, origin: origin)

        while let blockingFrame = occupiedFrames.first(where: { candidateFrame.paddedForPatchbay.intersects($0.paddedForPatchbay) }) {
            origin.y = blockingFrame.maxY + 24
            candidateFrame = frame(for: node, origin: origin)
        }

        return origin
    }

    private func frame(for node: PatchbayNode, origin: CGPoint) -> CGRect {
        CGRect(
            x: origin.x,
            y: origin.y,
            width: PatchbayLayout.nodeWidth,
            height: baseLayout.nodeHeight(node)
        )
    }
}

private extension CGRect {
    var paddedForPatchbay: CGRect {
        insetBy(dx: -12, dy: -12)
    }
}

private struct PatchbayLayout {
    static let nodeWidth: CGFloat = 260
    private static let horizontalPadding: CGFloat = 30
    private static let topPadding: CGFloat = 28
    private static let bottomPadding: CGFloat = 70
    private static let rightPadding: CGFloat = 120
    private static let columnGap: CGFloat = 300
    private static let nodeGap: CGFloat = 24
    private static let headerHeight: CGFloat = 44
    private static let portHeight: CGFloat = 32

    let graph: PatchbayGraph
    let width: CGFloat
    let height: CGFloat
    let defaultOrigins: [PatchbayNode.ID: CGPoint]

    private let origins: [PatchbayNode.ID: CGPoint]

    init(graph: PatchbayGraph, overrides: [PatchbayNode.ID: CGPoint] = [:]) {
        self.graph = graph

        var defaultOrigins: [PatchbayNode.ID: CGPoint] = [:]
        let leftNodes = graph.nodes.filter { $0.side == .left }
        let centerNodes = graph.nodes.filter { $0.side == .center }
        let rightNodes = graph.nodes.filter { $0.side == .right }

        var leftY = Self.topPadding
        for node in leftNodes {
            defaultOrigins[node.id] = CGPoint(x: Self.horizontalPadding, y: leftY)
            leftY += Self.nodeHeight(portCount: node.ports.count) + Self.nodeGap
        }

        var centerY = Self.topPadding
        let centerX = Self.horizontalPadding + Self.nodeWidth + Self.columnGap
        for node in centerNodes {
            defaultOrigins[node.id] = CGPoint(x: centerX, y: centerY)
            centerY += Self.nodeHeight(portCount: node.ports.count) + Self.nodeGap
        }

        var rightY = Self.topPadding
        let rightX = Self.horizontalPadding + Self.nodeWidth * 2 + Self.columnGap * 2
        for node in rightNodes {
            defaultOrigins[node.id] = CGPoint(x: rightX, y: rightY)
            rightY += Self.nodeHeight(portCount: node.ports.count) + Self.nodeGap
        }

        self.defaultOrigins = defaultOrigins
        origins = defaultOrigins.merging(overrides) { _, override in override }

        let bounds = Self.bounds(graph: graph, origins: origins)
        width = max(
            Self.horizontalPadding * 2 + Self.nodeWidth * 3 + Self.columnGap * 2,
            bounds.maxX + Self.rightPadding
        )
        height = max(520, bounds.maxY + Self.bottomPadding)
    }

    func nodeHeight(_ node: PatchbayNode) -> CGFloat {
        Self.nodeHeight(portCount: node.ports.count)
    }

    func nodeOrigin(_ nodeID: PatchbayNode.ID) -> CGPoint {
        origins[nodeID] ?? defaultOrigins[nodeID] ?? .zero
    }

    func nodeCenter(_ nodeID: PatchbayNode.ID) -> CGPoint {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
            return .zero
        }
        let origin = nodeOrigin(nodeID)
        return CGPoint(
            x: origin.x + Self.nodeWidth / 2,
            y: origin.y + nodeHeight(node) / 2
        )
    }

    func portPoint(nodeID: PatchbayNode.ID, portID: PatchbayPort.ID) -> CGPoint? {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }),
              let portIndex = node.ports.firstIndex(where: { $0.id == portID }) else {
            return nil
        }

        let origin = nodeOrigin(nodeID)
        let y = origin.y + Self.headerHeight + 9 + CGFloat(portIndex) * Self.portHeight + Self.portHeight / 2
        let x = node.ports[portIndex].side == .trailing ? origin.x + Self.nodeWidth : origin.x
        return CGPoint(x: x, y: y)
    }

    private static func nodeHeight(portCount: Int) -> CGFloat {
        headerHeight + 18 + CGFloat(portCount) * portHeight
    }

    private static func bounds(graph: PatchbayGraph, origins: [PatchbayNode.ID: CGPoint]) -> CGRect {
        graph.nodes.reduce(CGRect.null) { partial, node in
            let origin = origins[node.id] ?? .zero
            let frame = CGRect(
                x: origin.x,
                y: origin.y,
                width: nodeWidth,
                height: nodeHeight(portCount: node.ports.count)
            )
            return partial.union(frame)
        }
    }
}

private struct PatchbayGrid: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor).opacity(0.55)))

            let step: CGFloat = 24
            var x: CGFloat = 0
            while x <= size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(0.08)), lineWidth: 1)
                x += step
            }

            var y: CGFloat = 0
            while y <= size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.secondary.opacity(0.08)), lineWidth: 1)
                y += step
            }
        }
    }
}

private struct PatchbayNodeView: View {
    let node: PatchbayNode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PatchbayNodeIcon(stream: node.stream, fallbackSystemImage: node.systemImage)

                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(node.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            VStack(spacing: 5) {
                ForEach(node.ports) { port in
                    PatchbayPortView(port: port)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 9)
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(node.kind.tint.opacity(0.52), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

private struct PatchbayPortView: View {
    let port: PatchbayPort

    var body: some View {
        HStack(spacing: 6) {
            if port.side == .trailing {
                Spacer(minLength: 0)
            }

            Text(port.title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(port.kind.tint.opacity(0.88))
                }
                .foregroundStyle(port.kind == .input ? .black : .white)

            if port.side == .leading {
                Spacer(minLength: 0)
            }
        }
    }
}

private struct PatchbayNodeIcon: View {
    let stream: AppAudioStream?
    let fallbackSystemImage: String

    private var appIcon: NSImage? {
        guard let stream else {
            return nil
        }

        if let processID = stream.processID,
           let runningApp = NSRunningApplication(processIdentifier: processID),
           let icon = runningApp.icon {
            return icon
        }

        if let bundleID = stream.bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
    }
}
