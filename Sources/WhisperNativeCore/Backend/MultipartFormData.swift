import Foundation

struct MultipartFormData {
    let boundary: String
    private var body = Data()

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    mutating func addTextField(name: String, value: String) {
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8Data)
        body.append("\(value)\r\n".utf8Data)
    }

    mutating func addFileField(name: String, filename: String, mimeType: String, data fileData: Data) {
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(fileData)
        body.append("\r\n".utf8Data)
    }

    func finalize() -> Data {
        var result = body
        result.append("--\(boundary)--\r\n".utf8Data)
        return result
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
