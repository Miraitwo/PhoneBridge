import AppKit
import Foundation
import UniformTypeIdentifiers

enum RemoteDragCodec {
    // Use a built-in UTI so SwiftUI and AppKit agree on the drag type without
    // requiring an exported declaration in Info.plist. The JSON stays local to
    // this drag session and is decoded only as PhoneBridge RemoteEntry values.
    static let typeIdentifier = UTType.data.identifier
    static let payloadPrefix = "phonebridge-v1:"

    static func provider(for entries: [RemoteEntry]) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(entries)) ?? Data()
        return NSItemProvider(item: data as NSData, typeIdentifier: typeIdentifier)
    }

    static func receive(_ providers: [NSItemProvider], completion: @escaping (Result<[RemoteEntry], Error>) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let entries = entries(from: data) else {
                completion(.failure(PhoneBridgeError.invalidDropData))
                return
            }
            completion(.success(entries))
        }
        return true
    }

    static func payload(for entries: [RemoteEntry]) -> String {
        let data = (try? JSONEncoder().encode(entries)) ?? Data()
        return payloadPrefix + data.base64EncodedString()
    }

    static func entries(from data: Data) -> [RemoteEntry]? {
        guard let entries = try? JSONDecoder().decode([RemoteEntry].self, from: data),
              !entries.isEmpty else {
            return nil
        }
        return entries
    }

    static func entries(from payload: String) -> [RemoteEntry]? {
        guard payload.hasPrefix(payloadPrefix),
              let data = Data(base64Encoded: String(payload.dropFirst(payloadPrefix.count))),
              let entries = entries(from: data) else {
            return nil
        }
        return entries
    }
}

enum LocalFileDragCodec {
    static let typeIdentifier = UTType.fileURL.identifier

    static func provider(for url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    static func receive(
        _ providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(typeIdentifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let lock = NSLock()
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                defer { group.leave() }
                guard let nsURL = object as? NSURL,
                      nsURL.isFileURL else { return }
                lock.lock()
                urls.append(nsURL as URL)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            var seen = Set<String>()
            completion(urls.filter { seen.insert($0.standardizedFileURL.path).inserted })
        }
        return true
    }
}
