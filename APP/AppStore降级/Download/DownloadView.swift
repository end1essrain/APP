//
//  DownloadView.swift
//  Created by pxx917144686 on 2025/09/04.
//

import SwiftUI
import Combine
import Foundation
import Network

#if canImport(UIKit)
import UIKit
import SafariServices
#endif
#if canImport(Vapor)
import Vapor
#endif
#if canImport(ZsignSwift)
import ZsignSwift
#endif

// 全局安装状态管理
@MainActor
class GlobalInstallationManager: ObservableObject, @unchecked Sendable {
    static let shared = GlobalInstallationManager()
    @Published var isAnyInstalling = false
    @Published var currentInstallingRequestId: UUID? = nil
    
    private init() {}
    
    func startInstallation(for requestId: UUID) -> Bool {
        guard !isAnyInstalling else { return false }
        isAnyInstalling = true
        currentInstallingRequestId = requestId
        return true
    }
    
    func finishInstallation() {
        isAnyInstalling = false
        currentInstallingRequestId = nil
    }
}

// HTTP服务器管理器
@MainActor
class HTTPServerManager: ObservableObject, @unchecked Sendable {
    static let shared = HTTPServerManager()
    private var activeServers: [UUID: SimpleHTTPServer] = [:]
    
    private init() {}
    
    func startServer(for requestId: UUID, port: Int, ipaPath: String, appInfo: AppInfo) {
        let server = SimpleHTTPServer(port: port, ipaPath: ipaPath, appInfo: appInfo)
        server.start()
        activeServers[requestId] = server
        NSLog("🚀 [HTTPServerManager] 启动服务器，端口: \(port)，请求ID: \(requestId)")
    }
    
    func stopServer(for requestId: UUID) {
        if let server = activeServers[requestId] {
            server.stop()
            activeServers.removeValue(forKey: requestId)
            NSLog("🛑 [HTTPServerManager] 停止服务器，请求ID: \(requestId)")
        }
    }
    
    func stopAllServers() {
        for (requestId, server) in activeServers {
            server.stop()
            NSLog("🛑 [HTTPServerManager] 停止服务器，请求ID: \(requestId)")
        }
        activeServers.removeAll()
        NSLog("🛑 [HTTPServerManager] 已停止所有服务器")
    }
}
#if canImport(ZipArchive)
import ZipArchive
#endif

// 解决View类型冲突
typealias SwiftUIView = SwiftUI.View

// MARK: - 现代卡片样式
struct ModernCard<Content: SwiftUIView>: SwiftUIView {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some SwiftUIView {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
                    .shadow(
                        color: Color.black.opacity(0.1),
                        radius: 8,
                        x: 0,
                        y: 4
                    )
            )
    }
}

// MARK: - Safari网页视图
#if canImport(UIKit)
struct SafariWebView: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    
    init(url: URL, isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil) {
        self.url = url
        self._isPresented = isPresented
        self.onDismiss = onDismiss
    }
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        
        let safariVC = SFSafariViewController(url: url, configuration: config)
        safariVC.delegate = context.coordinator
        
        return safariVC
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // 更新UI控制器
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let parent: SafariWebView
        
        init(_ parent: SafariWebView) {
            self.parent = parent
        }
        
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            parent.isPresented = false
            parent.onDismiss?()
        }
        
        func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
            if didLoadSuccessfully {
                NSLog("✅ [Safari WebView] 页面加载成功: \(parent.url)")
            } else {
                NSLog("❌ [Safari WebView] 页面加载失败: \(parent.url)")
            }
        }
    }
}
#endif

// MARK: - 必要的类型定义
public enum PackageInstallationError: Error, LocalizedError {
    case invalidIPAFile
    case installationFailed(String)
    case networkError
    case timeoutError
    
    public var errorDescription: String? {
        switch self {
        case .invalidIPAFile:
            return "无效的IPA文件"
        case .installationFailed(let reason):
            return "安装失败: \(reason)"
        case .networkError:
            return "网络错误"
        case .timeoutError:
            return "安装超时"
        }
    }
}

public struct AppInfo {
    public let name: String
    public let version: String
    public let bundleIdentifier: String
    public let path: String
    public let localPath: String?
    
    public init(name: String, version: String, bundleIdentifier: String, path: String, localPath: String? = nil) {
        self.name = name
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.localPath = localPath
    }
    
    // 兼容性属性
    public var bundleId: String {
        return bundleIdentifier
    }
}

// MARK: - CORS中间件
#if canImport(Vapor)
struct CORSMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        return next.respond(to: request).map { response in
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
            response.headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
            return response
        }
    }
}
#endif

// MARK: - HTTP功能器
#if canImport(Vapor)
class SimpleHTTPServer: NSObject, @unchecked Sendable {
    public let port: Int
    private let ipaPath: String
    private let appInfo: AppInfo
    private var app: Application?
    private var isRunning = false
    private let serverQueue = DispatchQueue(label: "simple.server.queue", qos: .userInitiated)
    private var plistData: Data?
    private var plistFileName: String?
    
    // 使用随机端口范围
    static func randomPort() -> Int {
        return Int.random(in: 4000...8000)
    }
    
    init(port: Int, ipaPath: String, appInfo: AppInfo) {
        self.port = port
        self.ipaPath = ipaPath
        self.appInfo = appInfo
        super.init()
    }
    
    // MARK: - UserDefaults相关方法
    static let userDefaultsKey = "SimpleHTTPServer"
    
    static func getSavedPort() -> Int? {
        return UserDefaults.standard.integer(forKey: "\(userDefaultsKey).port")
    }
    
    static func savePort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: "\(userDefaultsKey).port")
        UserDefaults.standard.synchronize()
    }
    
    func start() {
        NSLog("🚀 [HTTP服务器] 启动服务器，端口: \(port)")
        
        // 请求本地网络权限
        requestLocalNetworkPermission { [weak self] granted in
            if granted {
                self?.serverQueue.async { [weak self] in
                    Task { @MainActor in
                        await self?.startSimpleServer()
                    }
                }
            }
        }
    }
    
    private func requestLocalNetworkPermission(completion: @escaping @Sendable (Bool) -> Void) {
        // 创建网络监听器来触发权限对话框
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "NetworkPermission")
        
        monitor.pathUpdateHandler = { path in
            // 检查网络可用性
            let hasPermission = path.status == .satisfied || path.status == .requiresConnection
            DispatchQueue.main.async {
                completion(hasPermission)
            }
            monitor.cancel()
        }
        
        monitor.start(queue: queue)
        
        // 5秒后超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            monitor.cancel()
            completion(true) // 默认允许继续
        }
    }
    
    private func startSimpleServer() async {
        do {
            // 创建Vapor应用
            let config = Environment(name: "development", arguments: ["serve"])
            app = try await Application.make(config)
            
            // 配置服务器
            app?.http.server.configuration.port = port
            app?.http.server.configuration.address = .hostname("0.0.0.0", port: port)
            app?.http.server.configuration.tcpNoDelay = true
            app?.http.server.configuration.requestDecompression = .enabled
            app?.http.server.configuration.responseCompression = .enabled
            app?.threadPool = .init(numberOfThreads: 2)
            app?.http.server.configuration.tlsConfiguration = nil
            
            // 设置CORS中间件
            app?.middleware.use(CORSMiddleware())
            
            // 设置路由
            setupSimpleRoutes()
            
            // 启动服务器
            try await app?.execute()
            isRunning = true
            NSLog("✅ [HTTP服务器] 服务器已启动，端口: \(port)")
            
        } catch {
            NSLog("❌ [HTTP服务器] 启动失败: \(error)")
            isRunning = false
        }
    }
    
    private func setupSimpleRoutes() {
        guard let app = app else { return }
        
        // 健康检查端点
        app.get("health") { req -> String in
            return "OK"
        }
        
        // 提供IPA文件功能
        app.get("ipa", ":filename") { [weak self] req -> Response in
            guard let self = self,
                  let filename = req.parameters.get("filename"),
                  filename == self.appInfo.bundleIdentifier else {
                return Response(status: .notFound)
            }
            
            guard let ipaData = try? Data(contentsOf: URL(fileURLWithPath: self.ipaPath)) else {
                return Response(status: .notFound)
            }
            
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/octet-stream")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: ipaData)
            
            return response
        }
        
        // 提供IPA文件服务（直接通过bundleIdentifier访问）
        app.get(":filename") { [weak self] req -> Response in
            guard let self = self,
                  let filename = req.parameters.get("filename"),
                  filename == "\(self.appInfo.bundleIdentifier).ipa" else {
                return Response(status: .notFound)
            }
            
            guard let ipaData = try? Data(contentsOf: URL(fileURLWithPath: self.ipaPath)) else {
                return Response(status: .notFound)
            }
            
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/octet-stream")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: ipaData)
            
            return response
        }
        
        // 提供Plist文件功能
        app.get("plist", ":filename") { [weak self] req -> Response in
            guard let self = self,
                  let filename = req.parameters.get("filename"),
                  filename == self.appInfo.bundleIdentifier else {
                return Response(status: .notFound)
            }
            
            let plistData = self.generatePlistData()
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/xml")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: plistData)
            
            return response
        }
        
        // 提供Plist文件功能（通过base64编码的路径）
        app.get("i", ":encodedPath") { [weak self] req -> Response in
            guard let self = self,
                  let encodedPath = req.parameters.get("encodedPath") else {
                return Response(status: .notFound)
            }
            
            // 解码base64路径
            guard let decodedData = Data(base64Encoded: encodedPath.replacingOccurrences(of: ".plist", with: "")),
                  let decodedPath = String(data: decodedData, encoding: .utf8) else {
                return Response(status: .notFound)
            }
            
            NSLog("📄 [APP] 请求plist文件，解码路径: \(decodedPath)")
            
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/xml")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: self.generatePlistData())
            
            return response
        }
        
        // 安装页面路由
        app.get("install") { [weak self] req -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }
            
            // 生成外部manifest URL
            let externalManifestURL = self.generateExternalManifestURL()
            
            // 创建改进的自动安装页面
            let installPage = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>正在安装 \(self.appInfo.name)</title>
                <style>
                    * {
                        box-sizing: border-box;
                    }
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        margin: 0;
                        padding: 20px;
                        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                        color: white;
                        text-align: center;
                        min-height: 100vh;
                        display: flex;
                        flex-direction: column;
                        justify-content: center;
                        align-items: center;
                    }
                    .container {
                        background: rgba(255, 255, 255, 0.1);
                        padding: 30px;
                        border-radius: 20px;
                        backdrop-filter: blur(10px);
                        max-width: 400px;
                        width: 100%;
                        box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
                    }
                    .app-icon {
                        width: 80px;
                        height: 80px;
                        background: #007AFF;
                        border-radius: 16px;
                        margin: 0 auto 20px;
                        display: flex;
                        align-items: center;
                        justify-content: center;
                        font-size: 40px;
                        box-shadow: 0 4px 16px rgba(0, 122, 255, 0.3);
                    }
                    .app-info {
                        margin-bottom: 20px;
                    }
                    .app-name {
                        font-size: 24px;
                        font-weight: 600;
                        margin: 0 0 8px 0;
                    }
                    .app-version {
                        font-size: 16px;
                        opacity: 0.8;
                        margin: 0 0 4px 0;
                    }
                    .app-bundle {
                        font-size: 12px;
                        opacity: 0.6;
                        margin: 0;
                    }
                    .status {
                        margin-top: 20px;
                        font-size: 16px;
                        opacity: 0.9;
                        min-height: 24px;
                    }
                    .loading {
                        display: inline-block;
                        width: 20px;
                        height: 20px;
                        border: 3px solid rgba(255,255,255,.3);
                        border-radius: 50%;
                        border-top-color: #fff;
                        animation: spin 1s ease-in-out infinite;
                        margin-right: 10px;
                    }
                    .success {
                        color: #4CAF50;
                    }
                    .error {
                        color: #f44336;
                    }
                    .manual-install {
                        margin-top: 20px;
                        padding: 15px;
                        background: rgba(255, 255, 255, 0.1);
                        border-radius: 10px;
                        font-size: 14px;
                    }
                    .install-button {
                        background: #007AFF;
                        color: white;
                        border: none;
                        padding: 12px 24px;
                        border-radius: 8px;
                        font-size: 16px;
                        font-weight: 600;
                        cursor: pointer;
                        margin-top: 10px;
                        transition: background 0.3s;
                    }
                    .install-button:hover {
                        background: #0056CC;
                    }
                    .install-button:disabled {
                        background: #666;
                        cursor: not-allowed;
                    }
                    @keyframes spin {
                        to { transform: rotate(360deg); }
                    }
                    @keyframes fadeIn {
                        from { opacity: 0; transform: translateY(20px); }
                        to { opacity: 1; transform: translateY(0); }
                    }
                    .fade-in {
                        animation: fadeIn 0.5s ease-out;
                    }
                </style>
            </head>
            <body>
                <div class="container fade-in">
                    <div class="app-icon">📱</div>
                    <div class="app-info">
                        <h1 class="app-name">\(self.appInfo.name)</h1>
                        <p class="app-version">版本 \(self.appInfo.version)</p>
                        <p class="app-bundle">\(self.appInfo.bundleIdentifier)</p>
                    </div>
                    
                    <div class="status" id="status">
                        <span class="loading"></span>正在启动安装程序...
                    </div>
                    
                    <div class="manual-install" id="manualInstall" style="display: none;">
                        <p>如果自动安装失败，请点击下方按钮手动安装：</p>
                        <button class="install-button" id="manualButton" onclick="manualInstall()">
                            手动安装
                        </button>
                    </div>
                </div>
                
                <script>
                    let manifestURL = '';
                    let itmsURL = '';
                    let isInstalling = false; // 防止重复安装
                    let installSuccess = false; // 标记是否已成功启动安装
                    
                    // 页面加载完成后立即自动执行安装
                    window.onload = function() {
                        console.log('页面加载完成，开始自动安装...');
                        initializeInstallation();
                    };
                    
                    function initializeInstallation() {
                        // 使用外部manifest URL
                        manifestURL = '\(externalManifestURL)';
                        itmsURL = 'itms-services://?action=download-manifest&url=' + encodeURIComponent(manifestURL);
                        
                        console.log('Manifest URL:', manifestURL);
                        console.log('ITMS URL:', itmsURL);
                        
                        // 延迟一点时间确保页面完全加载
                        setTimeout(function() {
                            autoInstall();
                        }, 1000);
                    }
                    
                    function autoInstall() {
                        // 防止重复安装
                        if (isInstalling || installSuccess) {
                            console.log('安装正在进行中或已成功，跳过重复调用');
                            return;
                        }
                        
                        const status = document.getElementById('status');
                        const manualInstall = document.getElementById('manualInstall');
                        
                        isInstalling = true;
                        status.innerHTML = '<span class="loading"></span>正在启动安装程序...';
                        
                        console.log('开始安装尝试');
                        
                        try {
                            // 只使用直接跳转方法触发安装
                            window.location.href = itmsURL;
                            status.innerHTML = '<span class="success">✅ 已启动安装程序...</span>';
                            installSuccess = true;
                            
                            console.log('安装程序启动成功');
                            
                            // 如果跳转成功，3秒后显示成功信息
                            setTimeout(function() {
                                if (installSuccess) {
                                    status.innerHTML = '<span class="success">✅ 请查看iPhone桌面</span>';
                                    document.body.innerHTML = '<div class="container fade-in" style="text-align: center; padding: 50px; color: white;"><div class="app-icon">✅</div><h1>安装成功</h1><p>请查看iPhone桌面，应用正在安装中...</p><p style="font-size: 12px; opacity: 0.6;"></p></div>';
                                }
                            }, 3000);
                            
                        } catch (error) {
                            console.error('安装失败:', error);
                            status.innerHTML = '<span class="error">❌ 安装启动失败</span>';
                            manualInstall.style.display = 'block';
                            isInstalling = false;
                        }
                    }
                    
                    function manualInstall() {
                        if (isInstalling || installSuccess) {
                            console.log('安装正在进行中或已成功，忽略手动安装');
                            return;
                        }
                        
                        const button = document.getElementById('manualButton');
                        const status = document.getElementById('status');
                        
                        button.disabled = true;
                        button.textContent = '正在安装...';
                        status.innerHTML = '<span class="loading"></span>手动触发安装...';
                        isInstalling = true;
                        
                        try {
                            window.location.href = itmsURL;
                            status.innerHTML = '<span class="success">✅ 手动安装已启动</span>';
                            installSuccess = true;
                        } catch (error) {
                            status.innerHTML = '<span class="error">❌ 手动安装失败: ' + error.message + '</span>';
                            button.disabled = false;
                            button.textContent = '重试安装';
                            isInstalling = false;
                        }
                    }
                </script>
            </body>
            </html>
            """
            
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "text/html")
            response.body = .init(string: installPage)
            
            return response
        }
        
        // 图标路由
        app.get("icon", "display") { [weak self] req -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }
            
            // 返回默认图标或从IPA提取的图标
            let iconData = self.getDefaultIconData()
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "image/png")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: iconData)
            
            return response
        }
        
        app.get("icon", "fullsize") { [weak self] req -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }
            
            // 返回默认图标或从IPA提取的图标
            let iconData = self.getDefaultIconData()
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "image/png")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: iconData)
            
            return response
        }
        
        
        // 健康检查路由
        app.get("health") { req -> Response in
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/json")
            response.body = .init(string: "{\"status\":\"healthy\",\"timestamp\":\"\(Date().timeIntervalSince1970)\"}")
            return response
        }
    }
    
    func stop() {
        NSLog("🛑 [Simple HTTP功能器] 停止功能器")
        
        serverQueue.async { [weak self] in
            self?.app?.shutdown()
            self?.isRunning = false
        }
    }
    
    func setPlistData(_ data: Data, fileName: String) {
        self.plistData = data
        self.plistFileName = fileName
    }
    
    // MARK: - 生成URL
    private func generateExternalManifestURL() -> String {
        // 创建本地IPA URL
        let localIP = "127.0.0.1"
        let ipaURL = "http://\(localIP):\(port)/\(appInfo.bundleIdentifier).ipa"
        
        // 创建完整的IPA下载URL（包含签名参数）
        let fullIPAURL = "\(ipaURL)?sign=1"
        
        // 使用公共代理服务转发本地URL
        let proxyURL = "https://api.palera.in/genPlist?bundleid=\(appInfo.bundleIdentifier)&name=\(appInfo.bundleIdentifier)&version=\(appInfo.version)&fetchurl=\(fullIPAURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fullIPAURL)"
        
        NSLog("🔗 [APP] 外部manifest URL: \(proxyURL)")
        
        return proxyURL
    }
    
    // MARK: - 生成Plist文件数据
    private func generatePlistData() -> Data {
        let ipaURL = "http://127.0.0.1:\(port)/\(appInfo.bundleIdentifier).ipa"
        
        let plistContent: [String: Any] = [
            "items": [[
                "assets": [
                    [
                        "kind": "software-package",
                        "url": ipaURL
                    ]
                ],
                "metadata": [
                    "bundle-identifier": appInfo.bundleIdentifier,
                    "bundle-version": appInfo.version,
                    "kind": "software",
                    "title": appInfo.name
                ]
            ]]
        ]
        
        guard let plistData = try? PropertyListSerialization.data(
            fromPropertyList: plistContent,
            format: .xml,
            options: .zero
        ) else {
            return Data()
        }
        
        return plistData
    }
    
    // MARK: - 图标处理方法
    private func getDisplayImageURL() -> String {
        // 使用本地服务器提供图标
        return "http://127.0.0.1:\(port)/icon/display"
    }
    
    private func getFullSizeImageURL() -> String {
        // 使用本地服务器提供图标
        return "http://127.0.0.1:\(port)/icon/fullsize"
    }
    
    private func getDefaultIconData() -> Data {
        // 动态图标生成实现
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 57, height: 57))
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 57, height: 57))
        }
        return image.pngData() ?? Data()
        #else
        // 创建一个简单的1x1像素的PNG数据作为默认图标
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
            0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0x0F, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        return pngData
        #endif
    }
}
#endif

struct DownloadView: SwiftUIView {
    @StateObject private var vm: UnifiedDownloadManager = UnifiedDownloadManager.shared
    @State private var animateCards = false
    @State private var showThemeSelector = false
    @State private var scenePhase: ScenePhase = .active
    
    @EnvironmentObject var themeManager: ThemeManager

    var body: some SwiftUIView {
        ZStack {
            // 背景
            themeManager.backgroundColor
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 内容区域
                downloadManagementSegmentView
            }
        }
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    showThemeSelector.toggle()
                }) {
                    Image(systemName: themeManager.selectedTheme == .light ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(themeManager.selectedTheme == .light ? .orange : .blue)
                }
            }
        }
        .overlay(
            FloatingThemeSelector(isPresented: $showThemeSelector)
        )
        .onAppear {
            // 强制刷新UI
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                print("[DownloadView] 强制刷新UI")
                withAnimation(.easeInOut(duration: 0.5)) {
                    animateCards = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ForceRefreshUI"))) { _ in
            // 接收强制刷新通知 - 真机适配
            print("[DownloadView] 接收到强制刷新通知")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                print("[DownloadView] 真机适配强制刷新完成")
                withAnimation(.easeInOut(duration: 0.5)) {
                    animateCards = true
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            handleAppEnteredBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            handleAppBecameActive()
        }
    }
    
    // MARK: - 下载任务分段视图
    var downloadManagementSegmentView: some SwiftUIView {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 16) {
                // 内容区域间距
                Spacer(minLength: 16)
                
                if vm.downloadRequests.isEmpty {
                    emptyStateView
                        .scaleEffect(animateCards ? 1 : 0.9)
                        .opacity(animateCards ? 1 : 0)
                        .animation(.spring().delay(0.1), value: animateCards)
                } else {
                    downloadRequestsView
                }
                
                // 添加底部间距，确保内容不会紧贴底部导航栏
                Spacer(minLength: 65)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
    
        
    // MARK: - 下载请求视图
    private var downloadRequestsView: some SwiftUIView {
        ForEach(Array(vm.downloadRequests.enumerated()), id: \.element.id) { enumeratedItem in
            let index = enumeratedItem.offset
            let request = enumeratedItem.element
            DownloadCardView(
                request: request
            )
            .scaleEffect(animateCards ? 1 : 0.9)
            .opacity(animateCards ? 1 : 0)
            .animation(Animation.spring().delay(Double(index) * 0.1), value: animateCards)
        }
    }
    
private var emptyStateView: some View {
    VStack(spacing: 32) {
        // 图标
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 120, height: 120)
            .cornerRadius(24)
            .scaleEffect(animateCards ? 1.1 : 1)
            .opacity(animateCards ? 1 : 0.7)
            .animation(
                Animation.easeInOut(duration: 2).repeatForever(autoreverses: true),
                value: animateCards
            )
        
        // 空状态文本
        VStack(spacing: 8) {
            Text("暂无下载任务")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.vertical, 32)
}
    
    // MARK: - 应用生命周期管理
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            NSLog("📱 [DownloadView] 应用进入前台")
            handleAppBecameActive()
        case .inactive:
            NSLog("📱 [DownloadView] 应用变为非活跃状态")
            handleAppBecameInactive()
        case .background:
            NSLog("📱 [DownloadView] 应用进入后台")
            handleAppEnteredBackground()
        @unknown default:
            NSLog("📱 [DownloadView] 未知的应用状态变化")
        }
    }
    
    private func handleAppBecameActive() {
        // 应用从后台回到前台时的处理
        NSLog("🔄 [DownloadView] 恢复下载任务状态")
        
        // 恢复下载任务
        vm.restoreDownloadTasks()
        
        // 检查是否有未完成的安装任务
        checkAndResumeInstallations()
        
        // 刷新UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                animateCards = true
            }
        }
    }
    
    private func handleAppBecameInactive() {
        // 应用变为非活跃状态时的处理
        NSLog("⏸️ [DownloadView] 暂停下载任务")
        
        // 保存当前下载状态
        vm.saveDownloadTasks()
    }
    
    private func handleAppEnteredBackground() {
        // 应用进入后台时的处理
        NSLog("💾 [DownloadView] 保存下载任务状态")
        
        // 保存下载任务到持久化存储
        vm.saveDownloadTasks()
        
        // 暂停所有下载任务
        vm.pauseAllDownloads()
        
        // 停止HTTP服务器
        stopAllHTTPServers()
    }
    
    private func checkAndResumeInstallations() {
        // 检查是否有未完成的安装任务并恢复
        for request in vm.downloadRequests {
            if request.runtime.status == .completed,
               let localFilePath = request.localFilePath,
               FileManager.default.fileExists(atPath: localFilePath) {
                NSLog("🔄 [DownloadView] 发现可恢复的安装任务: \(request.name)")
                // 这里可以添加恢复安装的逻辑
            }
        }
    }
    
    private func stopAllHTTPServers() {
        // 停止所有HTTP服务器
        NSLog("🛑 [DownloadView] 停止所有HTTP服务器")
        HTTPServerManager.shared.stopAllServers()
    }
    
}

// MARK: - 下载卡片视图
struct DownloadCardView: SwiftUIView {
    @ObservedObject var request: DownloadRequest
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var globalInstallManager = GlobalInstallationManager.shared
    
    // 添加状态变量
    @State private var showDetailView = false
    @State private var showInstallView = false
    
    // 安装相关状态
    @State private var isInstalling = false
    @State private var installationProgress: Double = 0.0
    @State private var installationMessage: String = ""
    
    // Safari WebView状态
    @State private var showSafariWebView = false
    @State private var safariURL: URL?
    
    var body: some SwiftUIView {
        ModernCard {
            VStack(spacing: 16) {
                // APP信息行
                HStack(spacing: 16) {
                    // APP图标
                    AsyncImage(url: URL(string: request.package.iconURL ?? "")) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Image(systemName: "app.fill")
                            .font(.title2)
                            .foregroundColor(themeManager.accentColor)
                    }
                    .frame(width: 50, height: 50)
                    .cornerRadius(10)
                    
                    // APP详细信息 - 与图标紧密组合
                    VStack(alignment: .leading, spacing: 4) {
                        // APP名称
                        Text(request.package.name)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        // Bundle ID
                        Text(request.package.bundleIdentifier)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        
                        // 版本信息
                        Text("版本 \(request.version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        
                        // 文件大小信息（如果可用）
                        if let localFilePath = request.localFilePath,
                           FileManager.default.fileExists(atPath: localFilePath) {
                            if let fileSize = getFileSize(path: localFilePath) {
                                Text("文件大小: \(fileSize)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // 右上角按钮组
                    VStack(spacing: 4) {
                        // 删除按钮
                        Button(action: {
                            deleteDownload()
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.red)
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(Color.red.opacity(0.1))
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        // 分享按钮（仅在下载完成时显示）
                        if request.runtime.status == .completed,
                           let localFilePath = request.localFilePath,
                           FileManager.default.fileExists(atPath: localFilePath) {
                            Button(action: {
                                shareIPAFile(path: localFilePath)
                            }) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.blue)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        Circle()
                                            .fill(Color.blue.opacity(0.1))
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                
                // 进度条 - 显示所有下载相关状态
                if request.runtime.status == .downloading || 
                   request.runtime.status == .waiting || 
                   request.runtime.status == .paused ||
                   request.runtime.progressValue >= 0 {
                    progressView
                }
                
                // 安装进度条 - 显示安装状态
                if isInstalling {
                    installationProgressView
                }
                
                // 操作按钮
                actionButtons
            }
            .padding(16)
        }
    }
    
    // MARK: - 操作按钮
    private var actionButtons: some SwiftUIView {
        VStack(spacing: 8) {
            // 主要操作按钮
            HStack(spacing: 8) {
                // 下载失败时显示相应按钮
                if request.runtime.status == .failed {
                    if isUnpurchasedAppError() {
                        // 未购买应用，显示跳转App Store按钮
                        Button(action: {
                            openAppStore()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "app.badge")
                                Text("此APP疑似没有购买记录，跳转 App Store 购买")
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    } else {
                        // 其他错误，显示重试按钮
                        Button(action: {
                            retryDownload()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("重试")
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }
                
                Spacer()
            }
            
            // 下载完成时显示额外信息和操作按钮
            if request.runtime.status == .completed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        
                        Text("文件已保存到:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        // 安装按钮
                        if let localFilePath = request.localFilePath,
                           FileManager.default.fileExists(atPath: localFilePath) {
                            Button(action: {
                                startInstallation(for: request)
                            }) {
                                HStack(spacing: 6) {
                                    if isInstalling {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(0.8)
                                    } else if globalInstallManager.isAnyInstalling && globalInstallManager.currentInstallingRequestId != request.id {
                                        Image(systemName: "clock.fill")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.6))
                                    } else {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    
                                    if isInstalling {
                                        Text("安装中...")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                    } else if globalInstallManager.isAnyInstalling && globalInstallManager.currentInstallingRequestId != request.id {
                                        Text("等待中...")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.6))
                                    } else {
                                        Text("开始安装")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: isInstalling || (globalInstallManager.isAnyInstalling && globalInstallManager.currentInstallingRequestId != request.id) 
                                            ? [Color.gray, Color.gray.opacity(0.8)]
                                            : [Color.green, Color.green.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .cornerRadius(10)
                                .shadow(color: isInstalling || (globalInstallManager.isAnyInstalling && globalInstallManager.currentInstallingRequestId != request.id) 
                                    ? Color.gray.opacity(0.3) 
                                    : Color.green.opacity(0.3), radius: 4, x: 0, y: 2)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(isInstalling || (globalInstallManager.isAnyInstalling && globalInstallManager.currentInstallingRequestId != request.id))
                        }
                    }
                    
                    Text(request.localFilePath ?? "未知路径")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 16) // 缩进对齐
                }
                .padding(.horizontal, 4)
            }
        }
        .onTapGesture {
            handleCardTap()
        }
        .sheet(isPresented: $showSafariWebView) {
            if let url = safariURL {
                SafariWebView(
                    url: url,
                    isPresented: $showSafariWebView,
                    onDismiss: {
                        NSLog("🔒 [DownloadCardView] Safari WebView已关闭")
                    }
                )
            }
        }
    }
    
    // MARK: - 卡片点击处理
    private func handleCardTap() {
        switch request.runtime.status {
        case .completed:
            // 下载完成时，显示安装选项
            if let localFilePath = request.localFilePath, FileManager.default.fileExists(atPath: localFilePath) {
                showInstallView = true
            } else {
                // 如果文件不存在，显示详情页面
                showDetailView = true
            }
        case .failed:
            // 下载失败时，显示详情页面
            showDetailView = true
        case .cancelled:
            // 下载取消时，显示详情页面
            showDetailView = true
        default:
            // 其他状态时，显示详情页面
            showDetailView = true
        }
    }
    

    

    
    // MARK: - 分享功能
    private func shareIPAFile(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            print("❌ 文件不存在: \(path)")
            return
        }
        
        let fileURL = URL(fileURLWithPath: path)
        
        #if os(iOS)
        // iOS平台使用UIActivityViewController
        let activityViewController = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        
        // 设置分享标题
        activityViewController.setValue("分享IPA文件", forKey: "subject")
        
        // 获取当前窗口的根视图控制器
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            // 在iPad上需要设置popoverPresentationController
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = rootViewController.view
                popover.sourceRect = CGRect(x: rootViewController.view.bounds.midX, 
                                          y: rootViewController.view.bounds.midY, 
                                          width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            rootViewController.present(activityViewController, animated: true) {
                print("✅ 分享界面已显示")
            }
        }
        #else
        #endif
    
    print("📤 [分享] 准备分享IPA文件: \(path)")
    }
    
    private var statusIndicator: some SwiftUIView {
        Group {
            switch request.runtime.status {
            case .waiting:
                Image(systemName: "clock")
                    .foregroundColor(.orange)
            case .downloading:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .foregroundColor(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            case .cancelled:
                Image(systemName: "xmark.circle")
                    .foregroundColor(.gray)
            }
        }
        .font(.title2)
    }
    
    private var progressView: some SwiftUIView {
        VStack(spacing: 4) {
            HStack {
                Label(getProgressLabel(), systemImage: getProgressIcon())
                    .font(.headline)
                    .foregroundColor(getProgressColor())
                
                Spacer()
                
                Text("\(Int(request.runtime.progressValue * 100))%")
                    .font(.title2)
                    .foregroundColor(themeManager.accentColor)
            }
            
            ProgressView(value: request.runtime.progressValue)
                .progressViewStyle(LinearProgressViewStyle(tint: getProgressColor()))
                .scaleEffect(y: 2.0)
            
            HStack {
                Spacer()
                
                Text(request.createdAt.formatted())
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // 获取进度标签
    private func getProgressLabel() -> String {
        switch request.runtime.status {
        case .waiting:
            return "等待下载"
        case .downloading:
            return "正在下载"
        case .paused:
            return "已暂停"
        case .completed:
            return "下载完成"
        case .failed:
            return "下载失败"
        case .cancelled:
            return "已取消"
        }
    }
    
    // 获取进度图标
    private func getProgressIcon() -> String {
        switch request.runtime.status {
        case .waiting:
            return "clock"
        case .downloading:
            return "arrow.down.circle"
        case .paused:
            return "pause.circle"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "xmark.circle"
        case .cancelled:
            return "xmark.circle"
        }
    }
    
    // 获取进度颜色
    private func getProgressColor() -> Color {
        switch request.runtime.status {
        case .waiting:
            return .orange
        case .downloading:
            return themeManager.accentColor
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }
    
    // 获取状态文本
    private func getStatusText() -> String {
        switch request.runtime.status {
        case .waiting:
            return "等待下载"
        case .downloading:
            return "正在下载"
        case .paused:
            return "已暂停"
        case .completed:
            return "下载完成"
        case .failed:
            return "下载失败"
        case .cancelled:
            return "已取消"
        }
    }
    
    // 获取状态颜色
    private func getStatusColor() -> Color {
        switch request.runtime.status {
        case .waiting:
            return .orange
        case .downloading:
            return .blue
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }
    
    // 获取文件大小
    private func getFileSize(path: String) -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attributes[.size] as? Int64 {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useGB]
                formatter.countStyle = .file
                return formatter.string(fromByteCount: fileSize)
            }
        } catch {
            print("获取文件大小失败: \(error)")
        }
        return nil
    }
    
    // MARK: - 安装进度视图
    private var installationProgressView: some SwiftUIView {
        VStack(spacing: 4) {
            HStack {
                Label("安装进度", systemImage: "arrow.up.circle")
                    .font(.headline)
                    .foregroundColor(.green)
                
                Spacer()
                
                Text("\(Int(installationProgress * 100))%")
                    .font(.title2)
                    .foregroundColor(.green)
            }
            
            ProgressView(value: installationProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: .green))
                .scaleEffect(y: 2.0)
            
            Text(installationMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 4)
    }

    
    // MARK: - 下载管理方法
    private func deleteDownload() {
        UnifiedDownloadManager.shared.deleteDownload(request: request)
    }
    
    private func retryDownload() {
        UnifiedDownloadManager.shared.startDownload(for: request)
    }
    
    // MARK: - 错误检测和App Store跳转
    private func isUnpurchasedAppError() -> Bool {
        guard let errorMessage = request.runtime.error else { return false }
        
        // 检测常见的未购买应用错误信息
        let unpurchasedKeywords = [
            "应用未购买",
            "未购买",
            "license",
            "purchase",
            "购买",
            "songList为空",
            "用户可能未购买此应用",
            "请先前往App Store购买"
        ]
        
        return unpurchasedKeywords.contains { keyword in
            errorMessage.localizedCaseInsensitiveContains(keyword)
        }
    }
    
    private func openAppStore() {
        // 构建App Store链接
        let appStoreURL = "https://apps.apple.com/app/id\(request.package.identifier)"
        
        guard let url = URL(string: appStoreURL) else {
            print("❌ [App Store] 无法创建App Store链接: \(appStoreURL)")
            return
        }
        
        print("🔗 [App Store] 正在打开App Store链接: \(appStoreURL)")
        
        #if canImport(UIKit)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url) { success in
                if success {
                    print("✅ [App Store] 成功打开App Store")
                } else {
                    print("❌ [App Store] 打开App Store失败")
                }
            }
        } else {
            print("❌ [App Store] 无法打开App Store链接")
        }
        #endif
    }
    
    // MARK: - 安装功能
    private func startInstallation(for request: DownloadRequest) {
        // 全局安装状态检查
        guard globalInstallManager.startInstallation(for: request.id) else {
            NSLog("⚠️ [APP] 其他应用正在安装中，忽略当前请求")
            return
        }
        
        // 本地安装状态检查
        guard !isInstalling else { 
            NSLog("⚠️ [APP] 安装正在进行中，忽略重复点击")
            globalInstallManager.finishInstallation()
            return 
        }
        
        // 检查是否已经有本地文件
        guard let localFilePath = request.localFilePath,
              FileManager.default.fileExists(atPath: localFilePath) else {
            NSLog("❌ [APP] 本地文件不存在，无法安装")
            globalInstallManager.finishInstallation()
            return
        }
        
        NSLog("🚀 [APP] 开始安装流程 - 请求ID: \(request.id)")
        isInstalling = true
        installationProgress = 0.0
        installationMessage = "准备安装..."
        
        Task {
            do {
                try await performOTAInstallation(for: request)
                
                await MainActor.run {
                    installationProgress = 1.0
                    installationMessage = "安装成功完成"
                    isInstalling = false
                    globalInstallManager.finishInstallation()
                    NSLog("✅ [APP] 安装流程完成")
                }
            } catch {
                await MainActor.run {
                    installationMessage = "安装失败: \(error.localizedDescription)"
                    isInstalling = false
                    globalInstallManager.finishInstallation()
                    NSLog("❌ [APP] 安装流程失败: \(error)")
                }
            }
        }
    }
    
    
    private func performOTAInstallation(for request: DownloadRequest) async throws {
        NSLog("🔧 [APP] 开始安装流程")
        
        guard let localFilePath = request.localFilePath else {
            throw PackageInstallationError.invalidIPAFile
        }
        
        // 创建AppInfo
        let appInfo = AppInfo(
            name: request.package.name,
            version: request.version,
            bundleIdentifier: request.package.bundleIdentifier,
            path: localFilePath
        )
        
        await MainActor.run {
            installationMessage = "正在验证IPA文件..."
            installationProgress = 0.2
        }
        
        // 验证IPA文件是否存在
        guard FileManager.default.fileExists(atPath: localFilePath) else {
            throw PackageInstallationError.invalidIPAFile
        }
        
        await MainActor.run {
            installationMessage = "正在进行签名..."
            installationProgress = 0.4
        }
        
        // 执行签名
        try await self.performAdhocSigning(ipaPath: localFilePath, appInfo: appInfo)
        
        await MainActor.run {
            installationMessage = "签名成功，准备安装..."
            installationProgress = 0.6
        }
        
        // 启动HTTP服务器
        let serverPort = SimpleHTTPServer.randomPort()
        HTTPServerManager.shared.startServer(
            for: request.id,
            port: serverPort,
            ipaPath: localFilePath,
            appInfo: appInfo
        )
        
        // 等待服务器启动
        try await Task.sleep(nanoseconds: 4_000_000_000) // 等待4秒
        
        await MainActor.run {
            installationMessage = "正在生成安装URL..."
            installationProgress = 0.8
        }
        
        // 生成安装URL
        let manifestURL = "http://127.0.0.1:\(serverPort)/plist/\(appInfo.bundleIdentifier)"
        let _ = manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? manifestURL
        
        await MainActor.run {
            installationMessage = "正在打开iOS安装对话框..."
            installationProgress = 0.9
        }
        
        // 使用Safari WebView打开安装页面
        let localInstallURL = "http://127.0.0.1:\(serverPort)/install"
        
        if let installURL = URL(string: localInstallURL) {
            DispatchQueue.main.async {
                self.safariURL = installURL
                self.showSafariWebView = true
                
                // 设置自动关闭定时器
                DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                    if self.showSafariWebView {
                        self.showSafariWebView = false
                    }
                }
                
                // 延迟停止服务器
                DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                    HTTPServerManager.shared.stopServer(for: request.id)
                }
            }
        } else {
            throw PackageInstallationError.installationFailed("无法创建安装页面URL")
        }
        
        await MainActor.run {
            installationMessage = "iOS安装对话框已打开"
            installationProgress = 1.0
        }
    }
    
    // MARK: - 签名方法
    private func performAdhocSigning(ipaPath: String, appInfo: AppInfo) async throws {
        
        #if canImport(ZsignSwift)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                #if canImport(ZipArchive)
                let unzipSuccess = SSZipArchive.unzipFile(atPath: ipaPath, toDestination: tempDir.path)
                guard unzipSuccess else {
                    throw PackageInstallationError.installationFailed("IPA文件解压失败")
                }
                #else
                throw PackageInstallationError.installationFailed("需要ZipArchive库")
                #endif
                
                let payloadDir = tempDir.appendingPathComponent("Payload")
                let payloadContents = try FileManager.default.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)
                
                guard let appBundle = payloadContents.first(where: { $0.pathExtension == "app" }) else {
                    throw PackageInstallationError.installationFailed("未找到.app文件")
                }
                
                let appPath = appBundle.path
                let success = Zsign.sign(
                    appPath: appPath,
                    entitlementsPath: "",
                    customIdentifier: appInfo.bundleIdentifier,
                    customName: appInfo.name,
                    customVersion: appInfo.version,
                    adhoc: true,
                    removeProvision: true,
                    completion: { _, error in
                        if let error = error {
                            continuation.resume(throwing: PackageInstallationError.installationFailed("签名失败: \(error.localizedDescription)"))
                        } else {
                            continuation.resume()
                        }
                    }
                )
                
                if !success {
                    continuation.resume(throwing: PackageInstallationError.installationFailed("签名过程启动失败"))
                }
                
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #else
        throw PackageInstallationError.installationFailed("ZsignSwift库不可用")
        #endif
    }
}
