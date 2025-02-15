import ObjectiveC
import MachO

// MARK: - PowPow

struct PowPow {
    // MARK: Internal

    static var dyldMap: HashMap<String, UnsafeMutableRawPointer> = .init()
    static var origMap: HashMap<ObjectIdentifier, Pointer?> = .init()

    static func replace(
        _ _class: AnyClass,
        _ selector: Selector,
        with replacement: some Any,
        orig _orig: inout Pointer?
    ) -> JinxResult {
        var ret: JinxResult = .unknown
        
        if native.hasSuffix("libhooker.dylib") || native.hasSuffix("libellekit.dylib") {
            guard let ptr: UnsafeMutableRawPointer = unsafeBitCast(replacement, to: UnsafeMutableRawPointer?.self) else {
                return .badReplace
            }
            
            var orig: UnsafeMutableRawPointer?
            ret = libhookerMessage(_class, selector, with: ptr, orig: &orig)
            
            guard let orig else {
                return .badOrig
            }
            
            _orig = Pointer.raw(orig)
        } else {
            guard let ptr: OpaquePointer = unsafeBitCast(replacement, to: OpaquePointer?.self) else {
                return .badReplace
            }
            
            var orig: OpaquePointer?
            
            if native.isEmpty {
                ret = internalMessage(_class, selector, with: ptr, orig: &orig)
            } else {
                ret = substrateMessage(_class, selector, with: ptr, orig: &orig)
            }
            
            guard let orig else {
                return .badOrig
            }
            
            _orig = Pointer.opaque(orig)
        }

        return ret
    }

    static func replaceFunc(
        _ function: String,
        in image: String?,
        with replacement: UnsafeMutableRawPointer,
        orig: inout UnsafeMutableRawPointer?
    ) -> JinxResult {
        if native.isEmpty || isArm64e && native.hasSuffix("CydiaSubstrate") || native.hasPrefix("@") {
            return FishBones.rebind(function, in: image ?? current, with: replacement, orig: &orig)
        }

        if native.hasSuffix("libhooker.dylib") || native.hasSuffix("libellekit.dylib") {
            return libhookerFunc(function, in: image, with: replacement, orig: &orig)
        } else {
            return substrateFunc(function, in: image, with: replacement, orig: &orig)
        }
    }

    // MARK: Private

    private static let isArm64e: Bool = {
        guard let archRaw = NXGetLocalArchInfo().pointee.name else {
            return false
        }

        return strcasecmp(archRaw, "arm64e") == 0
    }()

    // Get the path of the current hooking engine so we can get symbols from it

    private static let native: String = {
        var paths: [String] = [
            "/usr/lib/libellekit.dylib",
            "/usr/lib/libhooker.dylib",
            "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            "@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            "@executable_path/Frameworks/libhooker.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
        ]
        
        // Resolve symlinks for rootless jailbreak
        
        for path in paths {
            var buffer: [Int8] = .init(repeating: 0, count: Int(PATH_MAX))
            let destRes: Int = readlink(path, &buffer, buffer.count)
            
            if destRes != -1 {
                paths.append(String(cString: buffer))
            }
        }

        return paths.first(where: { path in
            access(path, F_OK) == 0
        }) ?? ""
    }()

    // Get the current process as a backup if nil is passed as an argument for function hooks

    private static let current: String = "/private" + CommandLine.arguments[0]

    // Get and store symbols for external hooking engines (Libhooker, Substrate, etc.)

    private static func symbol<T>(
        _ sym: String,
        in image: String = native
    ) -> T? {
        // Check for cached symbol
        
        if let symPtr: UnsafeMutableRawPointer = dyldMap.get(sym) {
            return unsafeBitCast(symPtr, to: T?.self)
        }
        
        // Check for cached image
        
        if let imgPtr: UnsafeMutableRawPointer = dyldMap.get(image) {
            let symPtr: UnsafeMutableRawPointer = dlsym(imgPtr, sym)
            
            dyldMap.set(symPtr, for: sym)
            
            guard let fnSym: T = unsafeBitCast(symPtr, to: T?.self) else {
                dlclose(imgPtr)
                return nil
            }
            
            return fnSym
        }
        
        // This is the first hook, so cache both image and symbol
        
        let imgPtr: UnsafeMutableRawPointer = dlopen(image, RTLD_GLOBAL | RTLD_LAZY)
        let symPtr: UnsafeMutableRawPointer = dlsym(imgPtr, sym)
        
        dyldMap.set(imgPtr, for: image)
        dyldMap.set(symPtr, for: sym)
        
        if let fnSym: T = unsafeBitCast(symPtr, to: T?.self) {
            return fnSym
        }

        return nil
    }

    // MARK: Libhooker API

    private static func libhookerFunc(
        _ function: String,
        in image: String?,
        with replacement: UnsafeMutableRawPointer,
        orig: inout UnsafeMutableRawPointer?
    ) -> JinxResult {
        let msPath: String = "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
        
        guard let LHOpenImage: LHOpenImageType = symbol("LHOpenImage"),
              let LHCloseImage: LHCloseImageType = symbol("LHCloseImage"),
              let LHFindSymbols: LHFindSymbolsType = symbol("LHFindSymbols"),
              let MSFindSymbol: MSFindSymbolType = symbol("MSFindSymbol", in: msPath),
              let MSGetImageByName: MSGetImageByNameType = symbol("MSGetImageByName", in: msPath),
              let LHHookFunctions: LHHookFunctionsType = symbol("LHHookFunctions")
        else {
            return .noHookLib
        }
        
        var lhImage: OpaquePointer?
        var searchSyms: [UnsafeMutableRawPointer?] = .init(repeating: nil, count: 1)
        var symbolNames: UnsafePointer<Int8> = .init(strdup(function))
        
        if let _lhImage: OpaquePointer = LHOpenImage(image ?? current) {
            lhImage = _lhImage
            
            if !LHFindSymbols(lhImage!, &symbolNames, &searchSyms, 1) {
                LHCloseImage(lhImage)
            }
        } else {
            if let sym: UnsafeMutableRawPointer = MSFindSymbol(MSGetImageByName(image ?? current), function) {
                searchSyms[0] = sym
            }
        }
        
        guard searchSyms[0] != nil else {
            return .noFunction
        }
        
        var result: Int16 = 6
        
        // How tf does this work? I really have no idea. It shouldn't work.
        
        withUnsafeMutablePointer(to: &orig) { pointer in
            var hook: LHFunctionHook = .init(
                function: searchSyms[0],
                replacement: replacement,
                oldptr: pointer,
                options: nil
            )
            
            result = LHHookFunctions(&hook, 1)
        }
        
        if lhImage != nil {
            LHCloseImage(lhImage)
        }
        
        return resolveLHError(result)
    }
    
    private static func libhookerMessage(
        _ _class: AnyClass,
        _ selector: Selector,
        with replacement: UnsafeMutableRawPointer,
        orig: inout UnsafeMutableRawPointer?
    ) -> JinxResult {
        guard let LBHookMessage: LBHookMessageType = symbol("LBHookMessage", in: "/usr/lib/libblackjack.dylib") else {
            return .noHookLib
        }
        
        return resolveLHError(LBHookMessage(_class, selector, replacement, &orig))
    }
    
    private static func resolveLHError(
        _ err: Int16
    ) -> JinxResult {
        switch err {
            case 0:
                return .success
            case 1:
                return .noSelector
            case 2:
                return .shortFunc
            case 3:
                return .badInsn
            case 4:
                return .memPages
            case 5:
                return .noFunction
            default:
                return .unknown
        }
    }

    // MARK: Substrate API

    private static func substrateFunc(
        _ function: String,
        in image: String?,
        with replacement: UnsafeMutableRawPointer,
        orig: inout UnsafeMutableRawPointer?
    ) -> JinxResult {
        guard let MSFindSymbol: MSFindSymbolType = symbol("MSFindSymbol"),
              let MSGetImageByName: MSGetImageByNameType = symbol("MSGetImageByName"),
              let MSHookFunction: MSHookFunctionType = symbol("MSHookFunction")
        else {
            return .noHookLib
        }
        
        if image == nil {
            guard let sym: UnsafeMutableRawPointer = MSFindSymbol(nil, function)
            else {
                return .noFunction
            }
            MSHookFunction(sym, replacement, &orig)
            return .success
        }
        
        guard let sym: UnsafeMutableRawPointer = MSFindSymbol(MSGetImageByName(image ?? current), function) else {
            return .noFunction
        }

        MSHookFunction(sym, replacement, &orig)

        return .success
    }
    
    private static func substrateMessage(
        _ _class: AnyClass,
        _ selector: Selector,
        with replacement: OpaquePointer,
        orig: inout OpaquePointer?
    ) -> JinxResult {
        guard let MSHookMessageEx: MSHookMessageExType = symbol("MSHookMessageEx") else {
            return .noHookLib
        }
        
        MSHookMessageEx(_class, selector, replacement, &orig)
        
        return .success
    }
    
    // MARK: Internal API
    
    static func internalMessage(
        _ _class: AnyClass,
        _ selector: Selector,
        with replacement: OpaquePointer,
        orig _orig: inout OpaquePointer?
    ) -> JinxResult {
        let getMethod = class_isMetaClass(_class) ? class_getClassMethod : class_getInstanceMethod

        guard let method: Method = getMethod(_class, selector),
              let types: UnsafePointer<Int8> = method_getTypeEncoding(method)
        else {
            return .noSelector
        }

        let orig: OpaquePointer = class_addMethod(_class, selector, replacement, types) ?
            method_getImplementation(method) :
            method_setImplementation(method, replacement)

        _orig = orig

        return .success
    }
}
