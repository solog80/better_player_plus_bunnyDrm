import Foundation
import AVFoundation

public class BetterPlayerFairPlayAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    public let certificateURL: URL
    public let licenseURL: URL?
    public let headers: [String: String]?
    public let videoId: String?
    public let libraryId: String?

    // REMOVED: private let defaultLicenseServerURL = URL(string: "https://fps.ezdrm.com/api/licenses/")!
    // REMOVED: private var assetId: String = "" (we'll use videoId instead)

    public init(_ certificateURL: URL, 
                withLicenseURL licenseURL: URL?, 
                headers: [String: String]? = nil, 
                videoId: String? = nil,
                libraryId: String? = nil) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        self.headers = headers
        self.videoId = videoId
        self.libraryId = libraryId
        super.init()
    }

    private func getContentKeyFromLicenseServer(request spc: Data) -> Data? {
        // Determine which license URL to use
        guard let finalLicenseURL = getLicenseURL() else {
            print("Failed to construct license URL")
            return nil
        }
        
        var request = URLRequest(url: finalLicenseURL)
        request.httpMethod = "POST"
        
        // Your server expects JSON with base64 SPC
        let spcBase64 = spc.base64EncodedString()
        let requestBody: [String: Any] = ["spc": spcBase64]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            print("Failed to serialize request body")
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
            defer { semaphore.signal() }
            
            if let error = error {
                print("License request error: \(error)")
                return
            }
            
            guard let data = data else {
                print("No data received from license server")
                return
            }
            
            // Debug: Print raw response
            if let responseString = String(data: data, encoding: .utf8) {
                print("License server raw response: \(responseString)")
            }
            
            // Your server returns JSON with "ckc" field
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let ckcBase64 = json["ckc"] as? String,
                       let ckcData = Data(base64Encoded: ckcBase64) {
                        print("Successfully parsed CKC from response")
                        resultData = ckcData
                    } else if let errorMsg = json["error"] as? String {
                        print("License server error: \(errorMsg)")
                    } else {
                        print("No 'ckc' field found in response")
                        // Try to use raw data as CKC (some servers return raw CKC)
                        resultData = data
                    }
                }
            } catch {
                print("Failed to parse JSON response: \(error)")
                // Maybe the response is raw CKC
                resultData = data
            }
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        return resultData
    }

    private func getLicenseURL() -> URL? {
        // If licenseURL was provided directly, use it
        if let licenseURL = licenseURL {
            return licenseURL
        }
        
        // Otherwise construct from videoId and libraryId
        guard let videoId = videoId, 
              let libraryId = libraryId else {
            print("Missing videoId or libraryId for URL construction")
            return nil
        }
        
        // Your server format: /FairPlayLicense/{libraryId}/{videoId}
        let urlString = "https://video.bunnycdn.com/FairPlayLicense/\(libraryId)/\(videoId)"
        print("Constructed license URL: \(urlString)")
        return URL(string: urlString)
    }

    private func getAppCertificate() throws -> Data {
        print("Fetching certificate from: \(certificateURL)")
        
        // Fetch certificate data
        let data = try Data(contentsOf: certificateURL)
        
        // Debug: Print raw response
        if let responseString = String(data: data, encoding: .utf8) {
            print("Certificate server raw response: \(responseString)")
        }
        
        // Check if response is JSON with certificate field
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let certBase64 = json["certificate"] as? String {
            print("Found certificate in JSON response")
            guard let certData = Data(base64Encoded: certBase64) else {
                throw NSError(domain: "FairPlay", code: -1, 
                            userInfo: [NSLocalizedDescriptionKey: "Invalid base64 certificate"])
            }
            return certData
        }
        
        // Fallback: assume it's raw certificate data
        print("Assuming raw certificate data")
        return data
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, 
                              shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let assetURI = loadingRequest.request.url else {
            print("No asset URI in loading request")
            return false
        }
        
        let scheme = assetURI.scheme ?? ""
        guard scheme == "skd" else {
            print("Not a FairPlay scheme: \(scheme)")
            return false
        }
        
        print("Processing FairPlay request for: \(assetURI.absoluteString)")

        let certificate: Data
        do {
            certificate = try getAppCertificate()
            print("Certificate loaded successfully: \(certificate.count) bytes")
        } catch {
            print("Failed to load certificate: \(error)")
            loadingRequest.finishLoading(with: error)
            return true
        }

        let requestBytes: Data
        do {
            guard let contentIdData = assetURI.absoluteString.data(using: .utf8) else {
                print("Failed to convert asset URI to data")
                loadingRequest.finishLoading(with: nil)
                return true
            }
            requestBytes = try loadingRequest.streamingContentKeyRequestData(
                forApp: certificate, 
                contentIdentifier: contentIdData, 
                options: nil
            )
            print("Generated SPC: \(requestBytes.count) bytes")
        } catch {
            print("Failed to generate SPC: \(error)")
            loadingRequest.finishLoading(with: error)
            return true
        }

        // Get CKC from license server
        let responseData = getContentKeyFromLicenseServer(request: requestBytes)

        if let responseData = responseData, !responseData.isEmpty {
            print("Received CKC: \(responseData.count) bytes")
            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
            print("FairPlay request completed successfully")
        } else {
            print("No valid CKC received from license server")
            loadingRequest.finishLoading(with: NSError(
                domain: NSURLErrorDomain, 
                code: NSURLErrorBadServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "No valid license received from server"]
            ))
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, 
                              shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest) -> Bool {
        print("Processing FairPlay renewal request")
        return self.resourceLoader(resourceLoader, shouldWaitForLoadingOfRequestedResource: renewalRequest)
    }
}
