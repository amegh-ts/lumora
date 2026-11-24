import Foundation
import CMPV

enum MPV {
    static func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) {
        mpv_set_option_string(handle, name, value)
    }

    static func setProperty(_ handle: OpaquePointer, _ name: String, _ value: String) {
        mpv_set_property_string(handle, name, value)
    }

    static func string(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    @discardableResult
    static func command(_ handle: OpaquePointer, _ args: [String], async: Bool = true, replyID: UInt64 = 0) -> Int32 {
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer {
            for pointer in cArgs {
                free(pointer)
            }
        }
        return cArgs.withUnsafeMutableBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                async ? mpv_command_async(handle, replyID, pointer) : mpv_command(handle, pointer)
            }
        }
    }

    static func errorString(_ code: Int32) -> String {
        String(cString: mpv_error_string(code))
    }

    static func value(from node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING:
            guard let string = node.u.string else { return nil }
            return String(cString: string)
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0
        case MPV_FORMAT_INT64:
            return node.u.int64
        case MPV_FORMAT_DOUBLE:
            return node.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee else { return [] }
            var result: [Any] = []
            for index in 0..<Int(list.num) {
                if let value = value(from: list.values[index]) {
                    result.append(value)
                }
            }
            return result
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee else { return [:] }
            var result: [String: Any] = [:]
            for index in 0..<Int(list.num) {
                guard let key = list.keys?[index] else { continue }
                if let value = value(from: list.values[index]) {
                    result[String(cString: key)] = value
                }
            }
            return result
        default:
            return nil
        }
    }
}

final class WeakBox<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?

    init(_ object: Object? = nil) {
        self.object = object
    }
}

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int64 { return Double(value) }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int64 { return Int(value) }
        if let value = self[key] as? Double { return Int(value) }
        return nil
    }

    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func bool(_ key: String) -> Bool {
        self[key] as? Bool ?? false
    }
}
