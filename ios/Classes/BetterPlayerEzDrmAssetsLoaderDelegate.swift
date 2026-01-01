import Foundation
import AVFoundation

public class BetterPlayerEzDrmAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    public let certificateURL: URL
    public let licenseURL: URL?
    public let headers: [String: String]?
    public let videoId: String?  // Add this to store videoId from Flutter

    private var assetId: String = ""
    private let defaultLicenseServerURL = URL(string: "https://fps.ezdrm.com/api/licenses/")!

    public init(_ certificateURL: URL, withLicenseURL licenseURL: URL?, headers: [String: String]? = nil, videoId: String? = nil) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        self.headers = headers
        self.videoId = videoId
        super.init()
    }

    private func getContentKeyAndLeaseExpiryFromKeyServerModule(request spc: Data, assetId: String, customParams: String) -> Data? {
        // Determine which license URL to use
        let finalLicenseURL: URL
        
        if let licenseURL = licenseURL {
            finalLicenseURL = licenseURL
        } else if let videoId = videoId, 
                  let libraryId = extractLibraryId(from: certificateURL) {
            // Construct URL in your server's format: /FairPlayLicense/{libraryId}/{videoId}
            let urlString = "https://video.bunnycdn.com/FairPlayLicense/\(libraryId)/\(videoId)"
            guard let url = URL(string: urlString) else { return nil }
            finalLicenseURL = url
        } else {
            finalLicenseURL = defaultLicenseServerURL
        }
        
        var request = URLRequest(url: finalLicenseURL)
        request.httpMethod = "POST"
        
        // Use your server's expected format: JSON with base64 SPC
        let spcBase64 = spc.base64EncodedString()
        let requestBody: [String: Any] = ["spc": spcBase64]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }
        
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add custom headers if provided
        headers?.forEach { key, value in
            request.addValue(value, forHTTPHeaderField: key)
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else {
                resultData = nil
                semaphore.signal()
                return
            }
            
            // Your server returns JSON with "ckc" field
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ckcBase64 = json["ckc"] as? String,
                   let ckcData = Data(base64Encoded: ckcBase64) {
                    resultData = ckcData
                } else {
                    resultData = nil
                }
            } catch {
                resultData = nil
            }
            
            semaphore.signal()
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        return resultData
    }

    private func getAppCertificate() throws -> Data {
        // Your server returns JSON with "certificate" field, not raw certificate
        let data = try Data(contentsOf: certificateURL)
        
        // Check if response is JSON with certificate field
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let certBase64 = json["certificate"] as? String,
           let certData = Data(base64Encoded: certBase64) {
            return certData
        }
        
        // Fallback: assume it's raw certificate data
        return data
    }
    
    private func extractLibraryId(from url: URL) -> String? {
        // Extract libraryId from URL like: /FairPlayLicense/{libraryId}/{videoId}
        // or /FairPlay/{libraryId}/certificate
        let pathComponents = url.pathComponents
        if pathComponents.count >= 2 {
            // For /FairPlay/{libraryId}/certificate
            if pathComponents.contains("FairPlay") {
                if let libraryIdIndex = pathComponents.firstIndex(of: "FairPlay"),
                   libraryIdIndex + 1 < pathComponents.count {
                    return pathComponents[libraryIdIndex + 1]
                }
            }
            // For /FairPlayLicense/{libraryId}/{videoId}
            if pathComponents.contains("FairPlayLicense") {
                if let libraryIdIndex = pathComponents.firstIndex(of: "FairPlayLicense"),
                   libraryIdIndex + 1 < pathComponents.count {
                    return pathComponents[libraryIdIndex + 1]
                }
            }
        }
        return nil
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let assetURI = loadingRequest.request.url else { return false }
        let urlString = assetURI.absoluteString
        let scheme = assetURI.scheme ?? ""
        guard scheme == "skd" else { return false }

        if urlString.count >= 36 {
            let startIndex = urlString.index(urlString.endIndex, offsetBy: -36)
            assetId = String(urlString[startIndex...])
        }

        let certificate: Data
        do {
            certificate = try getAppCertificate()
        } catch {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorClientCertificateRejected))
            return true
        }

        let requestBytes: Data
        do {
            guard let contentIdData = urlString.data(using: .utf8) else {
                loadingRequest.finishLoading(with: nil)
                return true
            }
            requestBytes = try loadingRequest.streamingContentKeyRequestData(forApp: certificate, contentIdentifier: contentIdData, options: nil)
        } catch {
            loadingRequest.finishLoading(with: nil)
            return true
        }

        // Use your server's API format
        let responseData = getContentKeyAndLeaseExpiryFromKeyServerModule(request: requestBytes, assetId: assetId, customParams: "")

        if let responseData = responseData, !responseData.isEmpty {
            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
        } else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest) -> Bool {
        return self.resourceLoader(resourceLoader, shouldWaitForLoadingOfRequestedResource: renewalRequest)
    }
}
