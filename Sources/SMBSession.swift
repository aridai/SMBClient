//
//  SMBSession.swift
//  SMBClient
//
//  Created by Seth Faxon on 9/1/17.
//  Copyright © 2017 Filmic. All rights reserved.
//

import libdsm

public class SMBSession {
    internal var rawSession = smb_session_new() {
        didSet {
            print("rawSession updated: \(String(describing: rawSession))")
        }
    }
    internal var serialQueue = DispatchQueue(label: "SMBSession")

    lazy var dataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var lastRequestDate: Date?

    public var sessionGuestState: SessionGuestState?
    public var connected: Bool = false
    public var server: SMBServer
    public var credentials: Credentials

    public var maxTaskOperationCount = OperationQueue.defaultMaxConcurrentOperationCount

    // tasks
    var downloadTasks: [SessionDownloadTask] = []
    var uploadTasks: [SessionUploadTask] = []
    lazy var taskQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = self.maxTaskOperationCount
        return queue
    }()

    public init(server: SMBServer, credentials: SMBSession.Credentials = .guest) {
        self.server = server
        self.credentials = credentials
    }

    public func requestVolumes() -> Result<[SMBVolume]> {
        let conError = self.attemptConnection()
        // switch result/error
        if let error = conError {
            return Result.failure(error)
        }

        var list: smb_share_list? = smb_share_list.allocate(capacity: 1)

        let shareCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        shareCount.pointee = 0

        smb_share_get_list(self.rawSession, &list, shareCount)

        if shareCount.pointee == 0 {
            return Result.success([])
        }
        var results: [SMBVolume] = []

        var i = 0
        while i <= shareCount.pointee {
            guard let shareNameCString = smb_share_list_at(list!, i) else {
                i += 1
                continue
            }

            var shareName = String(cString: shareNameCString)
            // skip system shares suffixed by '$'
            if shareName.characters.last == "$" {
                i += 1
                continue
            }

            let f = SMBVolume(name: shareName, session: self)
            results.append(f)

            i += 1
        }
        return Result.success(results)
    }

    public func requestVolumes(completionQueue: DispatchQueue = DispatchQueue.main,
                               completion: @escaping (_ result: Result<[SMBVolume]>) -> Void) {
        let operation = BlockOperation()
        weak var weakOperation = operation

        let blockOperation = {
            if let weakOp = weakOperation, weakOp.isCancelled {
                return
            }
            let requestResult = self.requestVolumes()

            completionQueue.async {
                completion(requestResult)
            }
        }

        operation.addExecutionBlock(blockOperation)
        self.dataQueue.addOperation(operation)
    }

    public func requestItems(fromVolume volume: SMBVolume, atPath path: String) -> Result<[SMBItem]> {
        let conError = self.attemptConnection()
        // switch result/error
        if let error = conError {
            return Result.failure(error)
        }

        var shareId: UInt16 = smb_tid.max
        smb_tree_connect(self.rawSession, volume.name.cString(using: .utf8), &shareId)
        if shareId == smb_tid.max {
            return Result.success([])
        }

        var relativePath = path // wildcard to search
        if relativePath.count > 0 {
            relativePath += "/*"
        } else {
            relativePath += "*"
        }
        relativePath = relativePath.replacingOccurrences(of: "/", with: "\\")

        // \SampleMedia\*
        let statList = smb_find(self.rawSession, shareId, relativePath.cString(using: .utf8))
        let listCount = smb_stat_list_count(statList)
        if listCount == 0 {
            return Result.success([])
        }

        var results: [SMBItem] = []

        var i = 0
        while i < listCount {
            let item = smb_stat_list_at(statList, i)
            guard let stat = item else { i = i + 1; continue }
            guard let smbItem = SMBItem(stat: stat, session: self, parentDirectoryFilePath: relativePath) else {
                i += 1
                continue
            }

            if smbItem.name.first != "." {
                results.append(smbItem)
            }

            i += 1
        }

        return Result.success(results)
    }

    public func requestItems(fromVolume volume: SMBVolume,
                             atPath path: String,
                             completionQueue: DispatchQueue = DispatchQueue.main,
                             completion: @escaping (_ result: Result<[SMBItem]>) -> Void) {
        let operation = BlockOperation()
        weak var weakOperation = operation

        let blockOperation = {
            if let weakOp = weakOperation, weakOp.isCancelled {
                return
            }
            let requestResult = self.requestItems(fromVolume: volume, atPath: path)
            completionQueue.async {
                completion(requestResult)
            }
        }
        operation.addExecutionBlock(blockOperation)
        self.dataQueue.addOperation(operation)
    }

    public func attemptConnection() -> SMBSessionError? {
        var err: SMBSessionError?
        serialQueue.sync {
            err = self.attemptConnectionWithSessionPointer(smbSession: self.rawSession)
        }

        if err != nil {
            return err
        }

        self.sessionGuestState = SessionGuestState(rawValue: smb_session_is_guest(self.rawSession))

        return nil
    }

    internal func attemptConnectionWithSessionPointer(smbSession: OpaquePointer?) -> SMBSessionError? {

        // if we're connecting from a dowload task, and the sessions match, make sure to refresh them periodically
        if self.rawSession == smbSession {
            if let lrd = self.lastRequestDate {
                if Date().timeIntervalSince(lrd) > 60 {
                    smb_session_destroy(self.rawSession)
                    self.rawSession = smb_session_new()

                    self.connected = false
                }
            }
            self.lastRequestDate = Date()
        }

        // don't attempt another connection if already connected
        if smb_session_is_guest(self.rawSession) >= 0 {
            self.connected = true
            return nil
        }

        // attempt a connection
        let connectionResult = smb_session_connect(self.rawSession,
                                                   server.hostname.cString(using: .utf8),
                                                   server.ipAddress,
                                                   Int32(SMB_TRANSPORT_TCP))
        if connectionResult != 0 {
            return SMBSessionError.unableToConnect
        }

        smb_session_set_creds(self.rawSession,
                              self.server.hostname.cString(using: .utf8),
                              self.credentials.userName.cString(using: .utf8),
                              self.credentials.password.cString(using: .utf8))
        if smb_session_login(self.rawSession) != 0 {
            return SMBSessionError.authenticationFailed
        }
        self.connected = true

        return nil
    }

    public func downloadTaskForFile(atPath path: String,
                                    destinationPath: String?,
                                    delegate: SessionDownloadTaskDelegate?) -> SessionDownloadTask {
        let task = SessionDownloadTask(session: self,
                                       sourceFilePath: path,
                                       destinationFilePath: destinationPath,
                                       delegate: delegate)
        self.downloadTasks.append(task)
        return task
    }

    @discardableResult public func uploadTaskForFile(atPath path: String,
                                                     data: Data,
                                                     delegate: SessionUploadTaskDelegate?) -> SessionUploadTask {
        let task = SessionUploadTask(session: self, path: path, data: data)
        task.delegate = delegate
        self.uploadTasks.append(task)
        return task
    }

    func cancelAllRequests() {
        self.dataQueue.cancelAllOperations()
    }

    deinit {
        guard let s = self.rawSession else { return }
        smb_session_destroy(s)
    }
}

extension SMBSession {
    public enum SessionGuestState: Int32 {
        case guest = 1
        case user = 0
        case error = -1
    }

    public enum SMBSessionError: Error {
        case unableToResolveAddress
        case unableToConnect
        case authenticationFailed
    }

    public enum Credentials {
        case guest
        case user(name: String, password: String)

        var userName: String {
            switch self {
            case .guest:
                return " " //
            case .user(let name, _):
                return name
            }
        }

        var password: String {
            switch self {
            case .guest:
                return " "
            case .user(_, let pass):
                return pass
            }
        }
    }
}

extension SMBSession.Credentials: CustomStringConvertible {
    public var description: String {
        switch self {
        case .guest:
            return "guest"
        case .user(let name, _):
            return "User: \(name) pass: ******"
        }
    }
}

extension SMBSession: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "hostname : \(String(describing: self.server.hostname))\n" +
               "ipAddress : \(self.server.ipAddressString)\n" +
               "credentials : \(self.credentials)\n"
    }

}
