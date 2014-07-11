//
//  ActiveSocket.swift
//  TestSwiftyCocoa
//
//  Created by Helge Hess on 6/11/14.
//  Copyright (c) 2014 Always Right Institute. All rights reserved.
//

import Darwin
import Dispatch

typealias ActiveSocketIPv4 = ActiveSocket<sockaddr_in>

/**
 * Represents an active STREAM socket based on the standard Unix sockets
 * library.
 *
 * An active socket can be either a socket gained by calling accept on a
 * passive socket or by explicitly connecting one to an address (a client
 * socket).
 * Therefore an active socket has two addresses, the local and the remote one.
 *
 * There are three methods to perform a close, this is rooted in the fact that
 * a socket actually is full-duplex, it provides a send and a receive channel.
 * The stream-mode is updated according to what channels are open/closed. 
 * Initially the socket is full-duplex and you cannot reopen a channel that was
 * shutdown. If you have shutdown both channels the socket can be considered
 * closed.
 *
 * Sample:
 *   let socket = ActiveSocket()
 *
 *   socket.onRead {
 *     let (count, block) = $0.read()
 *     if count < 1 {
 *       println("EOF, or great error handling.")
 *       return
 *     }
 *     println("Answer to ring,ring is: \(count) bytes: \(block)")
 *   }
 *
 *   socket.connect(sockaddr_in(address:"127.0.0.1", port: 80))
 *   socket.write("Ring, ring!\r\n")
 */
class ActiveSocket<T: SocketAddress>: Socket<T> {
  
  var remoteAddress  : T?                 = nil
  var queue          : dispatch_queue_t?  = nil
  var readSource     : dispatch_source_t? = nil
  var sendCount      : Int                = 0
  var closeRequested : Bool               = false
  var didCloseRead   : Bool               = false
  var readCB         : ((ActiveSocket, Int) -> Void)? = nil
  
  // let the socket own the read buffer, what is the best buffer type?
  var readBuffer     : [CChar] =  [CChar](count: 4096 + 2, repeatedValue: 42)
  var readBufferSize : Int = 4096 { // available space, a bit more for '\0'
    didSet {
      if readBufferSize != oldValue {
        readBuffer = [CChar](count: readBufferSize + 2, repeatedValue: 42)
      }
    }
  }
  
  
  var isConnected : Bool {
    // doesn't work: return isValid ? (remoteAddress != nil) : false
    if !isValid { return false }
    if let a = remoteAddress { return true } else { return false }
  }
  
  
  /* init */
  
  init(fd: Int32?) { // required, otherwise the convenience one fails to compile
    super.init(fd: fd)
  }
  
  convenience init(fd: Int32?, remoteAddress: T?, queue: dispatch_queue_t? = nil)
  {
    self.init(fd: fd)
    
    self.remoteAddress  = remoteAddress
    self.queue          = queue
    
    if let lfd = fd {
      isSigPipeDisabled = true
    }
  }
  
  
  /* close */
  
  override func close() {
    if debugClose { println("closing socket \(self)") }
    if !isValid { // already closed
      if debugClose { println("   already closed.") }
      return
    }
    
    // always shutdown receiving end, should call shutdown()
    // TBD: not sure whether we have a locking issue here, can read&write
    //      occur on different threads in GCD?
    if !didCloseRead {
      if debugClose { println("   stopping events ...") }
      stopEventHandler()
      // Seen this crash - if close() is called from within the readCB?
      readCB = nil // break potential cycles
      if debugClose { println("   shutdown read channel ...") }
      Darwin.shutdown(fd!, SHUT_RD);
      
      didCloseRead = true
    }
    
    if sendCount > 0 {
      if debugClose { println("   sends pending, requesting close ...") }
      closeRequested = true
      return
    }
    
    queue = nil // explicitly release, might be a good idea ;-)
    
    if debugClose { println("   super close.") }
    super.close()
  }
  
  
  /* connect */
  
  func connect(address: T, onConnect: () -> Void) -> Bool {
    // FIXME: make connect() asynchronous via GCD
    if !isValid {
      return false
    }
    if isConnected {
      // TBD: could be tolerant if addresses match
      println("Socket is already connected \(self)")
      return false
    }
    
    // Note: must be 'var' for ptr stuff, can't use let
    var addr = address
    
    let rc = withUnsafePointer(&addr) {
      (ptr: UnsafePointer<T>) -> Int32 in
      let bptr = ConstUnsafePointer<sockaddr>(ptr) // cast
      
      // connect!
      return Darwin.connect(self.fd!, bptr, socklen_t(addr.len))
    }
    
    if rc != 0 {
      println("Could not connect \(self) to \(addr)")
      return false
    }
    
    remoteAddress = addr
    onConnect()
    
    return true
  }
  
  /* read */
  
  func onRead(cb: ((ActiveSocket, Int) -> Void)?) -> Self {
    var hadCB    = false // this doesn't work anymore: let hadCB = readCB != nil
    var hasNewCB = false // doesn't work anymore: if cb == nil
    if let cb  = readCB { hadCB    = true }
    if let ncb = cb     { hasNewCB = true }
    
    if !hasNewCB && hadCB {
      stopEventHandler()
    }
    
    readCB = cb
    
    if hasNewCB && !hadCB {
      startEventHandler()
    }
    
    return self
  }
  
  // This doesn't work, can't override a stored property
  // Leaving this feature alone for now, doesn't have real-world importance
  // @lazy override var boundAddress: T? = getRawAddress()
  
  
  /* description */
  
  override func descriptionAttributes() -> String {
    // must be in main class, override not available in extensions
    var s = super.descriptionAttributes()
    if remoteAddress {
      s += " remote=\(remoteAddress)"
    }
    return s
  }
}


extension ActiveSocket : OutputStream { // writing
  
  // no let in extensions: let debugAsyncWrites = false
  var debugAsyncWrites : Bool { return false }
  
  func asyncWrite<T>(buffer: [T], length: Int? = nil) -> Bool {
    if !isValid {
      assert(isValid, "Socket closed, can't do async writes anymore")
      return false
    }
    if closeRequested {
      assert(!closeRequested, "Socket is being shutdown already!")
      return false
    }
    
    let writelen = length ? UInt(length!) : UInt(buffer.count)
    let bufsize  = writelen * UInt(sizeof(T))
    if bufsize < 1 { // Nothing to write ..
      return true
    }
    
    if queue == nil {
      println("No queue set, using main queue")
      queue = dispatch_get_main_queue()
    }
    
    // the default destructor is supposed to copy the data. Not good, but
    // handling ownership is going to be messy
    var asyncData  : dispatch_data_t? = nil
    asyncData = dispatch_data_create(buffer, bufsize, queue, nil)
    
    sendCount++
    if debugAsyncWrites {
      println("async send[\(sendCount)] size \(bufsize) \(buffer)")
    }
    
    // in here we capture self, which I think is right.
    dispatch_write(fd!, asyncData, queue) {
      asyncData, error in
      
      if self.debugAsyncWrites {
        println("did send[\(self.sendCount)] size \(bufsize) error \(error)")
      }
      
      self.sendCount = self.sendCount - 1 // -- fails?
      
      if self.sendCount == 0 && self.closeRequested {
        if self.debugAsyncWrites {
          println("closing after async write ...")
        }
        self.close()
        self.closeRequested = false
      }
    }
    
    asyncData = nil
    
    return true
  }
  
  func send<T>(buffer: [T], length: Int? = nil) -> Int {
    var writeCount : Int = 0
    let bufsize    = length ? UInt(length!) : UInt(buffer.count)
    let fd         = self.fd!
    
    buffer.withUnsafePointerToElements {
      p in
      writeCount = Darwin.write(fd, p, bufsize)
    }
    return writeCount
  }
  
  func write(string: String) {
    string.withCString { (p: CString) -> Void in
      if let cstr = p.persist() {
        let len = cstr.count - 1 // remove \0 terminator
        if len > 0 {
          self.asyncWrite(cstr, length: len)
        }
      }
      else {
        assert(false, "Could not persist cString")
        println("FATAL: Could not persist cString?")
      }
    }
  }
  
}


extension ActiveSocket { // Reading
  
  // Note: Swift doesn't allow the readBuffer in here.
  
  func read() -> ( size: Int, block: [CChar], error: Int32) {
    if !isValid {
      println("Called read() on closed socket \(self)")
      return ( -42, readBuffer, EBADF )
    }
    
    var readCount: Int = 0
    let bufsize = UInt(readBufferSize)
    let fd      = self.fd!
    
    // FIXME: If I just close the Terminal which hosts telnet this continues
    //        to read garbage from the server. Even with SIGPIPE off.
    readBuffer.withUnsafePointerToElements {
      p in readCount = Darwin.read(fd, p, bufsize)
    }
    
    if readCount < 0 {
      readBuffer[0] = 0
      return ( readCount, readBuffer, errno )
    }
    
    readBuffer[readCount] = 0 // convenience
    return ( readCount, readBuffer, 0 )
  }
  
  
  /* setup read event handler */
  
  func stopEventHandler() {
    if readSource {
      dispatch_source_cancel(readSource)
      readSource = nil // abort()s if source is not resumed ...
    }
  }
  
  func startEventHandler() -> Bool {
    if readSource {
      println("Read source already setup?")
      return true // already setup
    }
    
    /* do we have a queue? */
    
    if queue == nil {
      println("No queue set, using main queue")
      queue = dispatch_get_main_queue()
    }
    
    /* setup GCD dispatch source */
    
    readSource = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_READ,
      UInt(fd!), // is this going to bite us?
      0,
      queue
    )
    if !readSource {
      println("Could not create dispatch source for socket \(self)")
      return false
    }
    
    readSource!.onEvent {
      [unowned self] _, readCount in
      if let cb = self.readCB {
        cb(self, Int(readCount))
      }
    }
    
    /* actually start listening ... */
    dispatch_resume(readSource)
    
    return true
  }
  
}

extension ActiveSocket { // ioctl
  
  var numberOfBytesAvailableForReading : Int? {
    // Note: this doesn't seem to work, returns 0
    var count = Int32(0)
    let rc    = ari_ioctlVip(fd!, FIONREAD, &count);
    println("rc \(rc)")
    return rc != -1 ? Int(count) : nil
  }
  
}
