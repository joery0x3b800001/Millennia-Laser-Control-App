import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

private enum AppError: LocalizedError {
    case noPorts
    case noConnection
    case invalidResponse(String)
    case serialError(String, Int32)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .noPorts:
            return "No serial ports were found. Connect the laser and rescan."
        case .noConnection:
            return "Connect to a laser before sending commands."
        case .invalidResponse(let response):
            return "Unexpected response from the laser: \(response)"
        case .serialError(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .timeout(let command):
            return "The laser did not reply to \(command) before the timeout."
        }
    }
}

private final class SerialPort: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.shaunjoe.MillenniaControl.serial")
    private var fileDescriptor: Int32 = -1

    func connect(path: String, expectedSerialNumber: String) async throws -> (
        identity: String,
        shutterDown: Bool,
        initialError: String
    ) {
        try await perform {
            guard self.fileDescriptor < 0 else {
                throw AppError.invalidResponse("A serial connection is already open.")
            }

            let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY)
            guard descriptor >= 0 else {
                throw AppError.serialError("Opening \(path)", errno)
            }

            self.fileDescriptor = descriptor
            do {
                var settings = termios()
                guard tcgetattr(descriptor, &settings) == 0 else {
                    throw AppError.serialError("Reading serial settings", errno)
                }

                cfmakeraw(&settings)
                guard cfsetispeed(&settings, speed_t(B9600)) == 0,
                      cfsetospeed(&settings, speed_t(B9600)) == 0 else {
                    throw AppError.serialError("Setting serial speed", errno)
                }
                settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
                settings.c_cflag |= tcflag_t(CS8 | CREAD | CLOCAL)
                settings.c_cc.16 = cc_t(0)
                settings.c_cc.17 = cc_t(10)
                guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
                    throw AppError.serialError("Configuring serial port", errno)
                }
                tcflush(descriptor, TCIOFLUSH)

                let identity = try self.commandLocked("*idn?")
                let fields = identity.split(separator: ",", omittingEmptySubsequences: false)
                guard identity.contains("Spectra_Physics,Millennia eV"), fields.count >= 4 else {
                    throw AppError.invalidResponse(identity)
                }

                let actualSerialNumber = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !expectedSerialNumber.isEmpty && actualSerialNumber != expectedSerialNumber {
                    throw AppError.invalidResponse(
                        "Found serial number \(actualSerialNumber), expected \(expectedSerialNumber)."
                    )
                }

                let shutterStatus = try self.commandLocked("?sht")
                guard let firstCharacter = shutterStatus.first, firstCharacter == "0" || firstCharacter == "1" else {
                    throw AppError.invalidResponse(shutterStatus)
                }
                let initialError = try self.commandLocked("?FH")
                return (identity, firstCharacter == "0", initialError)
            } catch {
                self.closeLocked()
                throw error
            }
        }
    }

    func command(_ command: String) async throws -> String {
        try await perform {
            try self.commandLocked(command)
        }
    }

    func disconnect() async {
        await performWithoutError {
            self.closeLocked()
        }
    }

    private func commandLocked(_ command: String) throws -> String {
        guard fileDescriptor >= 0 else {
            throw AppError.noConnection
        }

        let commandText = command.trimmingCharacters(in: .newlines)
        guard !commandText.isEmpty else {
            return ""
        }
        let bytes = Array((commandText + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(fileDescriptor, buffer.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if count < 0 && errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw AppError.serialError("Writing to the laser", errno)
            }
            written += count
        }

        guard commandText.first == "?" || commandText.first == "*" else {
            return ""
        }

        let deadline = Date().addingTimeInterval(1.5)
        var response = [UInt8]()
        while response.count < 4096 {
            let remainingMilliseconds = max(0, Int(deadline.timeIntervalSinceNow * 1000))
            guard remainingMilliseconds > 0 else {
                throw AppError.timeout(commandText)
            }

            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, nfds_t(1), Int32(remainingMilliseconds))
            if pollResult < 0 && errno == EINTR {
                continue
            }
            guard pollResult > 0 else {
                throw AppError.timeout(commandText)
            }

            var byte: UInt8 = 0
            let count = Darwin.read(fileDescriptor, &byte, 1)
            if count < 0 && errno == EINTR {
                continue
            }
            guard count == 1 else {
                throw AppError.serialError("Reading from the laser", errno)
            }
            if byte == 10 {
                break
            }
            if byte != 13 {
                response.append(byte)
            }
        }
        return String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func closeLocked() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performWithoutError(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class AppModel: ObservableObject {
    @Published var ports: [String] = []
    @Published var selectedPort = ""
    @Published var laserName = ""
    @Published var serialNumber = ""
    @Published var logPeriod = "30"
    @Published var logFilePath = ""
    @Published var commandText = ""
    @Published private(set) var commandResponse = ""
    @Published private(set) var isConnected = false
    @Published private(set) var isLogging = false
    @Published private(set) var shutterDown = false
    @Published private(set) var power = "--"
    @Published private(set) var rms = "--"
    @Published private(set) var averageRms = "--%"
    @Published private(set) var diodeTemperature = "--"
    @Published private(set) var crystalTemperature = "--"
    @Published private(set) var diodeCurrent = "--"
    @Published private(set) var diodeHours = "--"
    @Published private(set) var headHours = "--"
    @Published private(set) var laserHours = "--"
    @Published var errorMessage: String?
    @Published private(set) var detectedError = false

    private let serialPort = SerialPort()
    private let configurationURL: URL
    private var loggingTask: Task<Void, Never>?
    private var logHandle: FileHandle?
    private var recentPower = [Double]()
    private var recentRms = [Double]()
    private var lastStoreTime = Date.distantPast
    private var lastErrorResponse = ""

    init() {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MillenniaLaserControl", isDirectory: true)
        configurationURL = ProcessInfo.processInfo.arguments.configurationPath
            ?? supportDirectory.appendingPathComponent("config.txt")
        logFilePath = supportDirectory.appendingPathComponent("log.txt").path
        loadConfiguration()
        rescanPorts()
    }

    var connectionTitle: String {
        isConnected ? "Disconnect from laser" : "Connect to laser"
    }

    var shutterTitle: String {
        shutterDown ? "Open the shutter" : "Set the shutter down"
    }

    func rescanPorts() {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: "/dev")
            ports = names
                .filter { $0.hasPrefix("cu.") || $0.hasPrefix("ttys") }
                .map { "/dev/" + $0 }
                .sorted()
            if !ports.contains(selectedPort) {
                selectedPort = ports.first ?? ""
            }
        } catch {
            report(error)
        }
    }

    func toggleConnection() {
        if isConnected {
            Task { await disconnect() }
        } else {
            Task { await connect() }
        }
    }

    func connect() async {
        guard !selectedPort.isEmpty else {
            report(AppError.noPorts)
            return
        }
        do {
            let result = try await serialPort.connect(path: selectedPort, expectedSerialNumber: serialNumber)
            shutterDown = result.shutterDown
            lastErrorResponse = result.initialError
            isConnected = true
            persistConfiguration()
            if ProcessInfo.processInfo.arguments.contains("-start") {
                startLogging()
            }
        } catch {
            report(error)
        }
    }

    func disconnect() async {
        stopLogging()
        await serialPort.disconnect()
        isConnected = false
        commandResponse = ""
    }

    func toggleShutter() {
        guard isConnected else { return }
        Task {
            do {
                let nextState = !shutterDown
                _ = try await serialPort.command("sht:\(nextState ? "0" : "1")")
                shutterDown = nextState
            } catch {
                report(error)
            }
        }
    }

    func sendCommand() {
        guard isConnected else { return }
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        Task {
            do {
                commandResponse = try await serialPort.command(command)
                let normalizedCommand = command.lowercased()
                if normalizedCommand == "sht:0" {
                    shutterDown = true
                } else if normalizedCommand == "sht:1" {
                    shutterDown = false
                } else if normalizedCommand == "?sht", let status = commandResponse.first {
                    shutterDown = status == "0"
                }
            } catch {
                report(error)
            }
        }
    }

    func startLogging() {
        guard isConnected, !isLogging else { return }
        guard let interval = Double(logPeriod), interval.isFinite, interval > 0 else {
            report(AppError.invalidResponse("Logging period must be a positive number of seconds."))
            return
        }
        let destination = URL(fileURLWithPath: logFilePath).expandingTildeInPath
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw AppError.invalidResponse("Could not create log file at \(destination.path).")
                }
            }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd()
            let formatter = ISO8601DateFormatter()
            let displayName = laserName.isEmpty ? "" : " (\(laserName))"
            let header = "# \(formatter.string(from: Date())) - Started logging Millennia laser\(displayName)\n"
                + "# Timestamp\tPower\tRMS\tAvg.RMS\tT-dio.\tT.cry.\tDio.c.\tDio.h.\tHead-h.\tLas.-h.\tError\n"
            try handle.write(contentsOf: Data(header.utf8))
            logHandle = handle
            isLogging = true
            recentPower.removeAll()
            recentRms.removeAll()
            lastStoreTime = .distantPast
            persistConfiguration()
            loggingTask = Task { await runLogging(storeInterval: interval) }
        } catch {
            report(error)
        }
    }

    func stopLogging() {
        loggingTask?.cancel()
        loggingTask = nil
        isLogging = false
        if let handle = logHandle {
            do {
                try handle.close()
            } catch {
                report(error)
            }
            logHandle = nil
        }
    }

    func persistConfiguration() {
        do {
            try FileManager.default.createDirectory(
                at: configurationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let entries = [
                "logFilePath = \(logFilePath)",
                "logPeriod = \(logPeriod)",
                "comPort = \(selectedPort)",
                "laserName = \(laserName)",
                "serialNumber = \(serialNumber)"
            ]
            try (entries.joined(separator: "\n") + "\n").write(
                to: configurationURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            report(error)
        }
    }

    func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-start") else { return }
        Task {
            await connect()
        }
    }

    private func runLogging(storeInterval: Double) async {
        let formatter = ISO8601DateFormatter()
        while !Task.isCancelled && isConnected {
            do {
                let powerValue = try await serialPort.command("?p")
                try Task.checkCancellation()
                guard let measuredPower = Double(powerValue) else {
                    throw AppError.invalidResponse(powerValue)
                }
                power = "\(powerValue) W"
                recentPower.append(measuredPower + 10.3)
                let samplesForRms = 50
                if recentPower.count > samplesForRms {
                    recentPower.removeFirst(recentPower.count - samplesForRms)
                }
                if recentPower.count == samplesForRms {
                    let total = recentPower.reduce(0, +)
                    let squares = recentPower.reduce(0) { $0 + $1 * $1 }
                    let value = max(0, squares / (total * total) * Double(samplesForRms) - 1)
                    let rmsValue = sqrt(value) * 100
                    rms = String(format: "%.4f%%", rmsValue)
                    recentRms.append(rmsValue)
                }

                if Date().timeIntervalSince(lastStoreTime) >= storeInterval {
                    try await storeTelemetry(formatter: formatter)
                    try Task.checkCancellation()
                    lastStoreTime = Date()
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch is CancellationError {
                break
            } catch {
                report(error)
                stopLogging()
                break
            }
        }
    }

    private func storeTelemetry(formatter: ISO8601DateFormatter) async throws {
        let diodeTemp = try await serialPort.command("?T")
        try Task.checkCancellation()
        let crystalTemp = try await serialPort.command("?TT")
        try Task.checkCancellation()
        let current = try await serialPort.command("?C")
        try Task.checkCancellation()
        let electronicsHours = try await serialPort.command("?PSHRS")
        try Task.checkCancellation()
        let laserHeadHours = try await serialPort.command("?HEADHRS")
        try Task.checkCancellation()
        let diodeWorkHours = try await serialPort.command("?DH")
        try Task.checkCancellation()
        let laserError = try await serialPort.command("?FH")
        try Task.checkCancellation()

        diodeTemperature = "\(diodeTemp) C"
        crystalTemperature = "\(crystalTemp) C"
        diodeCurrent = "\(current) A"
        laserHours = electronicsHours
        headHours = laserHeadHours
        diodeHours = diodeWorkHours

        if laserError != lastErrorResponse {
            detectedError = true
            lastErrorResponse = laserError
        }
        let average = recentRms.isEmpty ? "NaN" : String(format: "%.4f", recentRms.reduce(0, +) / Double(recentRms.count))
        averageRms = "\(average)%"

        let line = [
            formatter.string(from: Date()),
            power.replacingOccurrences(of: " W", with: ""),
            rms.replacingOccurrences(of: "%", with: ""),
            average,
            diodeTemp,
            crystalTemp,
            current,
            diodeWorkHours,
            laserHeadHours,
            electronicsHours,
            laserError
        ].joined(separator: "\t") + "\n"
        guard let logHandle else {
            throw AppError.invalidResponse("The log file is not open.")
        }
        try logHandle.write(contentsOf: Data(line.utf8))
        recentRms.removeAll()
    }

    private func loadConfiguration() {
        guard let contents = try? String(contentsOf: configurationURL, encoding: .utf8) else { return }
        var values = [String: String]()
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        laserName = values["laserName"] ?? ""
        serialNumber = values["serialNumber"] ?? ""
        logPeriod = values["logPeriod"] ?? "30"
        if let configuredPath = values["logFilePath"], !configuredPath.isEmpty {
            logFilePath = configuredPath
        }
        selectedPort = values["comPort"] ?? ""
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}

private extension Array where Element == String {
    var configurationPath: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-config"),
              arguments.indices.contains(flag + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[flag + 1]).standardizedFileURL
    }
}

private extension URL {
    var expandingTildeInPath: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

@main
private struct MillenniaControlApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 760)
                .task {
                    model.startIfRequested()
                }
        }
        .windowResizability(.contentSize)
    }
}

private struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Picker("Serial port", selection: $model.selectedPort) {
                        ForEach(model.ports, id: \.self) { port in
                            Text(verbatim: port).tag(String(port))
                        }
                    }
                    .disabled(model.isConnected)
                    Button("Rescan", action: model.rescanPorts)
                        .disabled(model.isConnected)
                }
                TextField("Display name", text: $model.laserName)
                    .disabled(model.isConnected)
                TextField("Expected serial number (optional)", text: $model.serialNumber)
                    .disabled(model.isConnected)
                HStack {
                    Button(model.connectionTitle, action: model.toggleConnection)
                        .buttonStyle(.borderedProminent)
                    if model.isConnected {
                        Button(model.shutterTitle, action: model.toggleShutter)
                    }
                    Text(model.isConnected ? "Connected" : "Disconnected")
                        .foregroundStyle(model.isConnected ? .green : .secondary)
                }
            }

            Section("Laser readings") {
                LabeledContent("Power", value: model.power)
                LabeledContent(
                    "RMS power (last 5 sec) (Average RMS: \(model.averageRms))",
                    value: model.rms
                )
                LabeledContent("Diode temperature", value: model.diodeTemperature)
                LabeledContent("Crystal tower temperature", value: model.crystalTemperature)
                LabeledContent("Diode current", value: model.diodeCurrent)
                LabeledContent("Diode hours", value: model.diodeHours)
                LabeledContent("Laser head hours", value: model.headHours)
                LabeledContent("Electronics hours", value: model.laserHours)
                if model.detectedError {
                    Label("The laser reported an error. Query it with ?FH.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Logging") {
                TextField("Logging period (seconds)", text: $model.logPeriod)
                    .disabled(model.isLogging)
                TextField("Log file path", text: $model.logFilePath)
                    .disabled(model.isLogging)
                Button(model.isLogging ? "Stop logging" : "Start logging") {
                    if model.isLogging {
                        model.stopLogging()
                    } else {
                        model.startLogging()
                    }
                }
                .disabled(!model.isConnected)
            }

            Section("Command line") {
                HStack {
                    TextField("Laser command (e.g. ?IDN?)", text: $model.commandText)
                        .onSubmit(model.sendCommand)
                    Button("Send", action: model.sendCommand)
                        .disabled(!model.isConnected)
                }
                LabeledContent("Response", value: model.commandResponse.isEmpty ? "--" : model.commandResponse)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(model.laserName.isEmpty ? "Millennia Laser Control App" : model.laserName)
        .onChange(of: model.laserName) { _ in model.persistConfiguration() }
        .onChange(of: model.serialNumber) { _ in model.persistConfiguration() }
        .onChange(of: model.logPeriod) { _ in model.persistConfiguration() }
        .onChange(of: model.logFilePath) { _ in model.persistConfiguration() }
        .onChange(of: model.selectedPort) { _ in model.persistConfiguration() }
        .alert(
            "Millennia Laser Control",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
