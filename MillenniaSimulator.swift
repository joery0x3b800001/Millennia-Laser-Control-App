import Darwin
import Foundation

private struct SimulatorOptions {
    var serialNumber = "ML-SIM-0001"
    var errorCount = 0
    var errorPeriod: Double?

    init(arguments: [String]) throws {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--serial-number":
                guard arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty else {
                    throw SimulatorError.usage
                }
                serialNumber = arguments[index + 1]
                index += 2
            case "--errors":
                guard arguments.indices.contains(index + 1),
                      let count = Int(arguments[index + 1]),
                      count > 0 else {
                    throw SimulatorError.usage
                }
                errorCount = count
                index += 2
            case "--error-period":
                guard arguments.indices.contains(index + 1),
                      let period = Double(arguments[index + 1]),
                      period.isFinite,
                      period > 0 else {
                    throw SimulatorError.usage
                }
                errorPeriod = period
                index += 2
            case "--help", "-h":
                print("""
                Usage: millennia-simulator [--serial-number SERIAL] [--errors COUNT --error-period SECONDS]

                Creates a virtual serial port and simulates a Spectra-Physics Millennia eV laser.
                Select the printed /dev/ttys... path in the Mac control app.
                When configured, simulated fault-history responses change COUNT times, evenly spaced
                over SECONDS. Both error options must be provided together.
                """)
                exit(EXIT_SUCCESS)
            default:
                throw SimulatorError.usage
            }
        }
        guard (errorCount == 0) == (errorPeriod == nil) else {
            throw SimulatorError.usage
        }
    }
}

private enum SimulatorError: LocalizedError {
    case usage
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: millennia-simulator [--serial-number SERIAL] [--errors COUNT --error-period SECONDS]"
        case .systemCall(let operation, let code):
            return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

private struct MillenniaDevice {
    let serialNumber: String
    let errorCount: Int
    let errorPeriod: Double
    private var shutterDown = true
    private var startedAt = Date()
    private var sample = 0

    init(serialNumber: String, errorCount: Int, errorPeriod: Double?) {
        self.serialNumber = serialNumber
        self.errorCount = errorCount
        self.errorPeriod = errorPeriod ?? 1
    }

    mutating func response(to command: String) -> String? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()
        switch lowercased {
        case "*idn?":
            return "Spectra_Physics,Millennia eV,\(serialNumber),1.0"
        case "?sht":
            return shutterDown ? "0" : "1"
        case "?p":
            sample += 1
            let elapsed = Date().timeIntervalSince(startedAt)
            let reading = 10.0 + 0.035 * sin(elapsed * 1.7) + 0.012 * sin(Double(sample) * 0.8)
            return String(format: "%.4f", reading)
        case "?t":
            return String(format: "%.2f", 24.5 + 0.2 * sin(Date().timeIntervalSince(startedAt) / 30))
        case "?tt":
            return String(format: "%.2f", 25.1 + 0.15 * cos(Date().timeIntervalSince(startedAt) / 35))
        case "?c":
            return String(format: "%.3f", 18.2 + 0.05 * sin(Date().timeIntervalSince(startedAt) / 20))
        case "?pshrs":
            return String(format: "%.2f", 1234.5 + Date().timeIntervalSince(startedAt) / 3600)
        case "?headhrs":
            return String(format: "%.2f", 987.6 + Date().timeIntervalSince(startedAt) / 3600)
        case "?dh":
            return String(format: "%.2f", 765.4 + Date().timeIntervalSince(startedAt) / 3600)
        case "?fh":
            let elapsed = Date().timeIntervalSince(startedAt)
            let reportedErrors = min(errorCount, Int(elapsed / errorPeriod * Double(errorCount)))
            guard reportedErrors > 0 else { return "000" }
            return String(format: "SIM-ERROR-%03d", reportedErrors)
        case "sht:0":
            shutterDown = true
            return nil
        case "sht:1":
            shutterDown = false
            return nil
        default:
            if lowercased.hasPrefix("?") || lowercased.hasPrefix("*") {
                return "ERR,UNKNOWN COMMAND: \(normalized)"
            }
            return nil
        }
    }
}

private func runSimulator() throws -> Never {
    let options = try SimulatorOptions(arguments: CommandLine.arguments)
    var master: Int32 = -1
    var slave: Int32 = -1
    var pathBuffer = [CChar](repeating: 0, count: 256)

    let openResult = pathBuffer.withUnsafeMutableBufferPointer { path in
        openpty(&master, &slave, path.baseAddress, nil, nil)
    }
    guard openResult == 0 else {
        throw SimulatorError.systemCall("Creating virtual serial port", errno)
    }

    let devicePath = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    _ = slave

    print("Virtual Millennia laser ready.")
    print("Serial port: \(devicePath)")
    print("Select this port in Millennia Laser Control, or press Ctrl-C to stop.")
    fflush(stdout)

    var device = MillenniaDevice(
        serialNumber: options.serialNumber,
        errorCount: options.errorCount,
        errorPeriod: options.errorPeriod
    )
    var commandBytes = [UInt8]()
    while true {
        var byte: UInt8 = 0
        let count = Darwin.read(master, &byte, 1)
        if count < 0 && errno == EINTR {
            continue
        }
        if count == 0 || (count < 0 && (errno == EIO || errno == EPERM)) {
            usleep(100_000)
            continue
        }
        guard count == 1 else {
            throw SimulatorError.systemCall("Reading virtual serial port", errno)
        }
        guard byte == 10 || byte == 13 else {
            if commandBytes.count < 1024 {
                commandBytes.append(byte)
            }
            continue
        }
        guard !commandBytes.isEmpty else { continue }
        let command = String(decoding: commandBytes, as: UTF8.self)
        commandBytes.removeAll(keepingCapacity: true)
        guard let response = device.response(to: command) else { continue }

        let responseBytes = Array((response + "\r\n").utf8)
        var written = 0
        while written < responseBytes.count {
            let result = responseBytes.withUnsafeBytes { bytes in
                Darwin.write(master, bytes.baseAddress!.advanced(by: written), responseBytes.count - written)
            }
            if result < 0 && errno == EINTR {
                continue
            }
            guard result > 0 else {
                if errno == EIO {
                    break
                }
                throw SimulatorError.systemCall("Writing virtual serial response", errno)
            }
            written += result
        }
    }
}

do {
    try runSimulator()
} catch {
    fputs("millennia-simulator: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
