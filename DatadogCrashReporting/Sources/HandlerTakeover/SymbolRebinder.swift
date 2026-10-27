/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import MachO

/// A symbol whose imported address should point at another function.
internal struct SymbolRebinding {
    /// The symbol name as it appears in the symbol table, with its leading underscore (e.g. `_sigaction`).
    let name: String
    /// The function the image's symbol pointers are rewritten to.
    let replacement: UnsafeRawPointer
}

/// Rewrites the symbol pointers an image uses to call imported functions (its lazy and non-lazy symbol pointers),
/// so that calls made by that image reach a replacement function. The technique is the one of
/// facebook/fishhook (MIT) and KSCrash's `__cxa_throw` swapper.
///
/// Only images outside the system (`/usr/lib`, `/System/Library`) are rewritten: calls made by the OS itself are left
/// alone, and system images live in the read-only, signed shared cache.
internal enum SymbolRebinder {
    /// Rewrites the symbol pointers of one image.
    ///
    /// - Returns: The number of symbol pointers rewritten.
    @discardableResult
    static func rebind(_ rebindings: [SymbolRebinding], inImage header: UnsafePointer<mach_header>, slide: Int) -> Int {
        guard header.pointee.magic == MH_MAGIC_64, !isSystemImage(header) else {
            return 0
        }
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)

        var linkedit: UnsafePointer<segment_command_64>?
        var symtab: UnsafePointer<symtab_command>?
        var dysymtab: UnsafePointer<dysymtab_command>?
        var pointerSegments: [UnsafePointer<segment_command_64>] = []

        var command = UnsafeRawPointer(header64).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header64.pointee.ncmds {
            let loadCommand = command.assumingMemoryBound(to: load_command.self)
            switch loadCommand.pointee.cmd {
            case UInt32(LC_SEGMENT_64):
                let segment = command.assumingMemoryBound(to: segment_command_64.self)
                switch segmentName(segment) {
                case SEG_LINKEDIT: linkedit = segment
                case SEG_DATA, "__DATA_CONST": pointerSegments.append(segment)
                default: break
                }
            case UInt32(LC_SYMTAB):
                symtab = command.assumingMemoryBound(to: symtab_command.self)
            case UInt32(LC_DYSYMTAB):
                dysymtab = command.assumingMemoryBound(to: dysymtab_command.self)
            default:
                break
            }
            command = command.advanced(by: Int(loadCommand.pointee.cmdsize))
        }

        guard let linkedit, let symtab, let dysymtab, dysymtab.pointee.nindirectsyms > 0 else {
            return 0
        }

        let linkeditBase = UInt(bitPattern: slide) &+ UInt(linkedit.pointee.vmaddr) &- UInt(linkedit.pointee.fileoff)
        guard
            let symbols = UnsafePointer<nlist_64>(bitPattern: linkeditBase + UInt(symtab.pointee.symoff)),
            let strings = UnsafePointer<CChar>(bitPattern: linkeditBase + UInt(symtab.pointee.stroff)),
            let indirectSymbols = UnsafePointer<UInt32>(bitPattern: linkeditBase + UInt(dysymtab.pointee.indirectsymoff))
        else {
            return 0
        }

        var rewritten = 0
        for segment in pointerSegments {
            var section = UnsafeRawPointer(segment).advanced(by: MemoryLayout<segment_command_64>.size)
                .assumingMemoryBound(to: section_64.self)
            for _ in 0..<segment.pointee.nsects {
                let type = section.pointee.flags & UInt32(SECTION_TYPE)
                if type == UInt32(S_LAZY_SYMBOL_POINTERS) || type == UInt32(S_NON_LAZY_SYMBOL_POINTERS) {
                    rewritten += rebind(
                        rebindings,
                        in: section,
                        slide: slide,
                        isReadOnlySegment: segmentName(segment) == "__DATA_CONST",
                        symbols: symbols,
                        strings: strings,
                        indirectSymbols: indirectSymbols
                    )
                }
                section = section.advanced(by: 1)
            }
        }
        return rewritten
    }

    // swiftlint:disable:next function_parameter_count
    private static func rebind(
        _ rebindings: [SymbolRebinding],
        in section: UnsafePointer<section_64>,
        slide: Int,
        isReadOnlySegment: Bool,
        symbols: UnsafePointer<nlist_64>,
        strings: UnsafePointer<CChar>,
        indirectSymbols: UnsafePointer<UInt32>
    ) -> Int {
        let pointerCount = Int(section.pointee.size) / MemoryLayout<UnsafeRawPointer>.size
        guard
            pointerCount > 0,
            let slots = UnsafeMutablePointer<UnsafeRawPointer?>(bitPattern: UInt(bitPattern: slide) &+ UInt(section.pointee.addr))
        else {
            return 0
        }
        let indices = indirectSymbols.advanced(by: Int(section.pointee.reserved1))

        var rewritten = 0
        for index in 0..<pointerCount {
            let symbolIndex = indices[index]
            if symbolIndex & UInt32(INDIRECT_SYMBOL_ABS) != 0 || symbolIndex & UInt32(INDIRECT_SYMBOL_LOCAL) != 0 {
                continue
            }
            let name = strings.advanced(by: Int(symbols[Int(symbolIndex)].n_un.n_strx))
            guard let rebinding = rebindings.first(where: { strcmp(name, $0.name) == 0 }) else {
                continue
            }
            let slot = slots.advanced(by: index)
            if slot.pointee == rebinding.replacement {
                continue
            }
            if isReadOnlySegment {
                // `__DATA_CONST` is made read-only once dyld has bound it.
                let address = vm_address_t(UInt(bitPattern: slot))
                let size = vm_size_t(MemoryLayout<UnsafeRawPointer>.size)
                guard vm_protect(mach_task_self_, address, size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS else {
                    continue
                }
                slot.pointee = rebinding.replacement
                vm_protect(mach_task_self_, address, size, 0, VM_PROT_READ)
            } else {
                slot.pointee = rebinding.replacement
            }
            rewritten += 1
        }
        return rewritten
    }

    /// Whether the image belongs to the OS (including the simulator runtime).
    static func isSystemImage(_ header: UnsafePointer<mach_header>) -> Bool {
        // Images of the dyld shared cache, i.e. the OS's: checked first as it is cheap, and called for every image.
        let isInSharedCache = header.pointee.flags & 0x8000_0000 != 0 // MH_DYLIB_IN_CACHE
        guard !isInSharedCache else {
            return true
        }
        var info = Dl_info()
        guard dladdr(header, &info) != 0, let path = info.dli_fname else {
            return true
        }
        let imagePath = String(cString: path)
        return imagePath.hasPrefix("/usr/lib/")
            || imagePath.hasPrefix("/System/")
            || imagePath.contains("/RuntimeRoot/usr/lib/")
            || imagePath.contains("/RuntimeRoot/System/")
    }

    private static func segmentName(_ segment: UnsafePointer<segment_command_64>) -> String {
        withUnsafeBytes(of: segment.pointee.segname) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
