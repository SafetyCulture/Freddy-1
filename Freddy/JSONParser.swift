//
//  JSONParser.swift
//  Freddy
//
//  Created by John Gallagher on 4/18/15.
//  Copyright © 2015 Big Nerd Ranch. Licensed under MIT.
//

#if os(OSX) || os(iOS) || os(watchOS) || os(tvOS)
import Foundation
#endif

private enum Keyword: String {
    case False = "false"
    case Null  = "null"
    case True  = "true"
}

private struct Literal {
    static let BACKSLASH     = UInt8(ascii: "\\")
    static let BACKSPACE     = UInt8(ascii: "\u{0008}")
    static let COLON         = UInt8(ascii: ":")
    static let COMMA         = UInt8(ascii: ",")
    static let DOUBLE_QUOTE  = UInt8(ascii: "\"")
    static let FORMFEED      = UInt8(ascii: "\u{000c}")
    static let LEFT_BRACE    = UInt8(ascii: "{")
    static let LEFT_BRACKET  = UInt8(ascii: "[")
    static let MINUS         = UInt8(ascii: "-")
    static let NEWLINE       = UInt8(ascii: "\n")
    static let PERIOD        = UInt8(ascii: ".")
    static let PLUS          = UInt8(ascii: "+")
    static let RETURN        = UInt8(ascii: "\r")
    static let RIGHT_BRACE   = UInt8(ascii: "}")
    static let RIGHT_BRACKET = UInt8(ascii: "]")
    static let SLASH         = UInt8(ascii: "/")
    static let SPACE         = UInt8(ascii: " ")
    static let TAB           = UInt8(ascii: "\t")

    static let b = UInt8(ascii: "b")
    static let e = UInt8(ascii: "e")
    static let f = UInt8(ascii: "f")
    static let n = UInt8(ascii: "n")
    static let r = UInt8(ascii: "r")
    static let t = UInt8(ascii: "t")
    static let u = UInt8(ascii: "u")
    static let E = UInt8(ascii: "E")
    
    static var HexLower: Range<UInt8> { return UInt8(ascii: "a")...UInt8(ascii: "f") }
    static var HexUpper: Range<UInt8> { return UInt8(ascii: "A")...UInt8(ascii: "F") }
    static var Digits: Range<UInt8>   { return UInt8(ascii: "0")...UInt8(ascii: "9") }
}

private struct UnicodeLiteral {

}

private let ParserMaximumDepth = 512

/**
A pure Swift JSON parser. This parser is much faster than the
`NSJSONSerialization`-based parser (due to the overhead of having to
dynamically cast the Objective-C objects to determine their type); however,
it is much newer and has restrictions that the `NSJSONSerialization` parser
does not. Two restrictions in particular are that it requires UTF-8 data as
input and it does not allow trailing commas in arrays or dictionaries.
**/
public struct JSONParser {

    private enum Sign: Int {
        case Positive = 1
        case Negative = -1
    }

    private let input: UnsafeBufferPointer<UInt8>
    private let owner: Any?
    private var loc = 0
    private var depth = 0

    private init<T>(buffer: UnsafeBufferPointer<UInt8>, owner: T) {
        self.input = buffer
        self.owner = owner
    }

    public mutating func parse() throws -> JSON {
        let value = try parseValue()
        skipWhitespace()
        guard loc == input.count else {
            throw Error.EndOfStreamGarbage(offset: loc)
        }
        return value
    }

    private mutating func parseValue() throws -> JSON {
        guard depth <= ParserMaximumDepth else {
            throw Error.ExceededNestingLimit(offset: loc)
        }

        advancing: while loc < input.count {
            switch input[loc] {
            case Literal.LEFT_BRACKET:
                depth += 1
                defer { depth -= 1 }
                return try decodeArray()

            case Literal.LEFT_BRACE:
                depth += 1
                defer { depth -= 1 }
                return try decodeObject()

            case Literal.DOUBLE_QUOTE:
                return try decodeString()

            case Literal.f:
                return try decodeKeyword(.False, with: .Bool(false))

            case Literal.n:
                return try decodeKeyword(.Null, with: .Null)

            case Literal.t:
                return try decodeKeyword(.True, with: .Bool(true))

            case Literal.MINUS:
                return try decodeNumberNegative(loc)

            case Literal.Digits.startIndex:
                return try decodeNumberLeadingZero(loc)

            case Literal.Digits:
                return try decodeNumberPreDecimalDigits(loc)

            case Literal.SPACE, Literal.TAB, Literal.RETURN, Literal.NEWLINE:
                loc = loc.successor()

            default:
                break advancing
            }
        }
        
        throw Error.ValueInvalid(offset: loc, character: UnicodeScalar(input[loc]))
    }

    private mutating func skipWhitespace() {
        while loc < input.count {
            switch input[loc] {
            case Literal.SPACE, Literal.TAB, Literal.RETURN, Literal.NEWLINE:
                loc = loc.successor()

            default:
                return
            }
        }
    }

    private mutating func decodeKeyword(keyword: Keyword, @autoclosure with json: () -> JSON) throws -> JSON {
        let start = loc
        let end = start.advancedBy(keyword.rawValue.utf8.count - 1, limit: input.endIndex)

        guard end != input.endIndex else {
            throw Error.EndOfStreamUnexpected
        }
        
        guard input[start ... end].elementsEqual(keyword.rawValue.utf8) else {
            throw Error.KeywordMisspelled(offset: start, text: keyword.rawValue)
        }

        loc = end.successor()
        return json()
    }

    private mutating func scanUntilEndOfString() throws -> (UnsafeBufferPointer<UInt8>, hasEscapes: Bool) {
        // skip past the opening "
        loc = loc.successor()

        var range = loc..<loc
        var hasEscapes = false
        var inEscape = false

        loop: while true {
            guard loc != input.endIndex else {
                throw Error.EndOfStreamUnexpected
            }
            defer { loc = loc.successor() }

            switch input[loc] {
            case Literal.DOUBLE_QUOTE where !inEscape:
                range.endIndex = loc
                break loop
            case Literal.u where inEscape:
                inEscape = false
                hasEscapes = true
                loc = loc.advancedBy(4, limit: input.endIndex)
            case _ where inEscape:
                inEscape = false
                hasEscapes = true
            case Literal.BACKSLASH:
                inEscape = true
            default: break
            }
        }

        // input[loc] should at the closing " now
        let buffer = UnsafeBufferPointer(start: input.baseAddress.advancedBy(range.startIndex), count: range.count)
        return (buffer, hasEscapes)
    }

    private mutating func decodeString() throws -> JSON {
        // scan until we find the closing "
        let start = loc
        let (buffer, hasEscapes) = try scanUntilEndOfString()

        guard var string = String(bytesNoCopy: .init(buffer.baseAddress), length: buffer.count, encoding: NSUTF8StringEncoding, freeWhenDone: false) else {
            throw Error.UnicodeEscapeInvalid(offset: start)
        }

        if hasEscapes {
            try parseEscapes(&string, start: start)
        }

        return .String(string)
    }

    private var stringDecodingBuffer = [UInt8]()
    private mutating func decodeStringOld() throws -> JSON {
        let start = loc
        loc = loc.successor()

        stringDecodingBuffer.removeAll(keepCapacity: true)
        while loc < input.count {
            switch input[loc] {
            case Literal.BACKSLASH:
                loc = loc.successor()
                switch input[loc] {
                case Literal.DOUBLE_QUOTE: stringDecodingBuffer.append(Literal.DOUBLE_QUOTE)
                case Literal.BACKSLASH:    stringDecodingBuffer.append(Literal.BACKSLASH)
                case Literal.SLASH:        stringDecodingBuffer.append(Literal.SLASH)
                case Literal.b:            stringDecodingBuffer.append(Literal.BACKSPACE)
                case Literal.f:            stringDecodingBuffer.append(Literal.FORMFEED)
                case Literal.r:            stringDecodingBuffer.append(Literal.RETURN)
                case Literal.t:            stringDecodingBuffer.append(Literal.TAB)
                case Literal.n:            stringDecodingBuffer.append(Literal.NEWLINE)
                case Literal.u:
                    loc = loc.successor()
                    let escaped = try decodeUnicodeEscape()
                    stringDecodingBuffer.appendContentsOf(escaped)
                    continue

                default:
                    throw Error.ControlCharacterUnrecognized(offset: loc)
                }
                loc = loc.successor()

            case Literal.DOUBLE_QUOTE:
                loc = loc.successor()
                stringDecodingBuffer.append(0)

                guard let string = (stringDecodingBuffer.withUnsafeBufferPointer {
                    String.fromCString(UnsafePointer($0.baseAddress))
                }) else {
                    throw Error.UnicodeEscapeInvalid(offset: start)
                }

                return .String(string)

            case let other:
                stringDecodingBuffer.append(other)
                loc = loc.successor()
            }
        }

        throw Error.EndOfStreamUnexpected
    }

    private mutating func decodeUnicodeEscape() throws -> [UInt8] {
        let start = loc
        let end = start.advancedBy(3, limit: input.endIndex)

        guard end != input.endIndex else {
            throw Error.EndOfStreamUnexpected
        }

        var codepoint: UInt16 = 0
        for byte in input[start ... end] {
            let nibble: UInt16
            switch byte {
            case Literal.Digits:
                nibble = UInt16(byte - Literal.Digits.startIndex)

            case Literal.HexLower:
                nibble = 10 + UInt16(byte - Literal.HexLower.startIndex)

            case Literal.HexUpper:
                nibble = 10 + UInt16(byte - Literal.HexUpper.startIndex)

            default:
                throw Error.UnicodeEscapeInvalid(offset: start)
            }
            codepoint = (codepoint << 4) | nibble
        }
        
        loc = end.successor()
        
        // UTF16-to-UTF8, via wikipedia
        if codepoint <= 0x007f {
            return [UInt8(codepoint)]
        } else if codepoint <= 0x07ff {
            return [0b11000000 | UInt8(codepoint >> 6),
                0b10000000 | UInt8(codepoint & 0x3f)]
        } else {
            return [0b11100000 | UInt8(codepoint >> 12),
                0b10000000 | UInt8((codepoint >> 6) & 0x3f),
                0b10000000 | UInt8(codepoint & 0x3f)]
        }
    }

    private mutating func decodeArray() throws -> JSON {
        let start = loc
        loc = loc.successor()
        var items = [JSON]()

        while loc < input.count {
            skipWhitespace()

            if loc < input.count && input[loc] == Literal.RIGHT_BRACKET {
                loc = loc.successor()
                return .Array(items)
            }

            if !items.isEmpty {
                guard loc < input.count && input[loc] == Literal.COMMA else {
                    throw Error.CollectionMissingSeparator(offset: start)
                }
                loc = loc.successor()
            }

            items.append(try parseValue())
        }

        throw Error.EndOfStreamUnexpected
    }

    // Decoding objects can be recursive, so we have to keep more than one
    // buffer around for building up key/value pairs (to reduce allocations
    // when parsing large JSON documents).
    //
    // Rough estimate of the difference between this and using a fresh
    // [(String,JSON)] for the `pairs` variable in decodeObject() below is
    // about 12% on an iPhone 5.
    private struct DecodeObjectBuffers {
        var buffers = [[(String,JSON)]]()

        mutating func getBuffer() -> [(String,JSON)] {
            if !buffers.isEmpty {
                var buffer = buffers.removeLast()
                buffer.removeAll(keepCapacity: true)
                return buffer
            }
            return [(String,JSON)]()
        }

        mutating func putBuffer(buffer: [(String,JSON)]) {
            buffers.append(buffer)
        }
    }

    private var decodeObjectBuffers = DecodeObjectBuffers()

    private mutating func decodeObject() throws -> JSON {
        let start = loc
        loc = loc.successor()
        var pairs = decodeObjectBuffers.getBuffer()

        while loc < input.count {
            skipWhitespace()

            if loc < input.count && input[loc] == Literal.RIGHT_BRACE {
                loc = loc.successor()
                var obj = [String:JSON](minimumCapacity: pairs.count)
                for (k, v) in pairs {
                    obj[k] = v
                }
                decodeObjectBuffers.putBuffer(pairs)
                return .Dictionary(obj)
            }

            if !pairs.isEmpty {
                guard loc < input.count && input[loc] == Literal.COMMA else {
                    throw Error.CollectionMissingSeparator(offset: start)
                }
                loc = loc.successor()

                skipWhitespace()
            }

            guard loc < input.count && input[loc] == Literal.DOUBLE_QUOTE else {
                throw Error.DictionaryMissingKey(offset: start)
            }

            let key = try decodeString().string()
            skipWhitespace()

            guard loc < input.count && input[loc] == Literal.COLON else {
                throw Error.CollectionMissingSeparator(offset: start)
            }
            loc = loc.successor()

            pairs.append((key, try parseValue()))
        }

        throw Error.EndOfStreamUnexpected
    }

    private mutating func decodeNumberNegative(start: Int) throws -> JSON {
        loc = loc.successor()
        guard loc < input.count else {
            throw Error.EndOfStreamUnexpected
        }

        switch input[loc] {
        case Literal.Digits.startIndex:
            return try decodeNumberLeadingZero(start, sign: .Negative)

        case Literal.Digits:
            return try decodeNumberPreDecimalDigits(start, sign: .Negative)

        default:
            throw Error.NumberSymbolMissingDigits(offset: start)
        }
    }

    private mutating func decodeNumberLeadingZero(start: Int, sign: Sign = .Positive) throws -> JSON {
        loc = loc.successor()
        guard loc < input.count else {
            return .Int(0)
        }

        switch (input[loc], sign) {
        case (Literal.PERIOD, _):
            return try decodeNumberDecimal(start, sign: sign, value: 0)

        case (_, .Negative):
            return .Double(-0.0)

        default:
            return .Int(0)
        }
    }

    private mutating func decodeNumberPreDecimalDigits(start: Int, sign: Sign = .Positive) throws -> JSON {
        var value = 0

        advancing: while loc < input.count {
            let c = input[loc]
            switch c {
            case Literal.Digits:
                value = 10 * value + Int(c - Literal.Digits.startIndex)
                loc = loc.successor()

            case Literal.PERIOD:
                return try decodeNumberDecimal(start, sign: sign, value: Double(value))

            case Literal.e, Literal.E:
                return try decodeNumberExponent(start, sign: sign, value: Double(value))

            default:
                break advancing
            }
        }

        return .Int(sign.rawValue * value)
    }

    private mutating func decodeNumberDecimal(start: Int, sign: Sign, value: Double) throws -> JSON {
        loc = loc.successor()
        guard loc < input.count else {
            throw Error.EndOfStreamUnexpected
        }

        switch input[loc] {
        case Literal.Digits:
            return try decodeNumberPostDecimalDigits(start, sign: sign, value: value)

        default:
            throw Error.NumberMissingFractionalDigits(offset: start)
        }
    }

    private mutating func decodeNumberPostDecimalDigits(start: Int, sign: Sign, value inValue: Double) throws -> JSON {
        var value = inValue
        var position = 0.1

        advancing: while loc < input.count {
            let c = input[loc]
            switch c {
            case Literal.Digits:
                value += position * Double(c - Literal.Digits.startIndex)
                position /= 10
                loc = loc.successor()

            case Literal.e, Literal.E:
                return try decodeNumberExponent(start, sign: sign, value: value)

            default:
                break advancing
            }
        }

        return .Double(Double(sign.rawValue) * value)
    }

    private mutating func decodeNumberExponent(start: Int, sign: Sign, value: Double) throws -> JSON {
        loc = loc.successor()
        guard loc < input.count else {
            throw Error.EndOfStreamUnexpected
        }

        switch input[loc] {
        case Literal.Digits:
            return try decodeNumberExponentDigits(start, sign: sign, value: value, expSign: .Positive)

        case Literal.PLUS:
            return try decodeNumberExponentSign(start, sign: sign, value: value, expSign: .Positive)

        case Literal.MINUS:
            return try decodeNumberExponentSign(start, sign: sign, value: value, expSign: .Negative)

        default:
            throw Error.NumberSymbolMissingDigits(offset: start)
        }
    }

    private mutating func decodeNumberExponentSign(start: Int, sign: Sign, value: Double, expSign: Sign) throws -> JSON {
        loc = loc.successor()
        guard loc < input.count else {
            throw Error.EndOfStreamUnexpected
        }

        switch input[loc] {
        case Literal.Digits:
            return try decodeNumberExponentDigits(start, sign: sign, value: value, expSign: expSign)

        default:
            throw Error.NumberSymbolMissingDigits(offset: start)
        }
    }

    private mutating func decodeNumberExponentDigits(start: Int, sign: Sign, value: Double, expSign: Sign) throws -> JSON {
        var exponent: Double = 0

        advancing: while loc < input.count {
            let c = input[loc]
            switch c {
            case Literal.Digits:
                exponent = exponent * 10 + Double(c - Literal.Digits.startIndex)
                loc = loc.successor()

            default:
                break advancing
            }
        }

        return .Double(Double(sign.rawValue) * value * pow(10, Double(expSign.rawValue) * exponent))
    }
}

// MARK: - Unicode

private struct Escapes {

    typealias CodeUnit = UTF16.CodeUnit

    static var Backslash: CodeUnit { return u16("\\") }
    static var UnicodeEscapeStart: CodeUnit { return u16("u") }

    static func u16(scalar: UnicodeScalar) -> CodeUnit {
        return .init(truncatingBitPattern: scalar.value)
    }

    static func hexFrom(codeUnit: CodeUnit) -> CodeUnit? {
        let digits = u16("a") ... u16("f")
        let upper  = u16("A") ... u16("F")
        let lower  = u16("0") ... u16("9")

        switch codeUnit {
        case digits: return codeUnit &- digits.startIndex
        case upper:  return codeUnit &- upper.startIndex &+ CodeUnit(10)
        case lower:  return codeUnit &- lower.startIndex &+ CodeUnit(10)
        default:     return nil
        }
    }

    static func controlFrom(codeUnit: CodeUnit) -> UnicodeScalar? {
        switch codeUnit {
        case u16("\\"), u16("/"), u16("\""):
            return UnicodeScalar(codeUnit)
        case u16("b"): // backspace
            return "\u{8}"
        case u16("t"): // tab
            return "\u{9}"
        case u16("n"): // new line
            return "\u{a}"
        case u16("f"): // form feed
            return "\u{c}"
        case u16("r"): // carriage return
            return "\u{d}"
        default:
            return nil
        }
    }

    static func combineCodepoints(leading: CodeUnit, _ trailing: CodeUnit) -> UnicodeScalar {
        var codec = UTF16()
        var generator = [ leading, trailing ].generate()
        switch codec.decode(&generator) {
        case .Result(let scalar): return .init(scalar)
        case .EmptyInput:         return .init()
        case .Error:              return "\u{fffd}"
        }
    }

}

extension JSONParser {

    private enum EscapeParserState {
        case None
        // consumed a "\", now looking for a control character
        case BeginControl(String.UTF16Index)
        // parsing a Unicode escape
        case UnicodeEscape(String.UTF16Index, UInt16, remaining: Int)
        // got a Unicode character, but UTF-16 says we need another
        case NeedSurrogatePair(String.UTF16Index)
    }

    private func parseEscapes(inout string: String, start: Int) throws {
        var priorCodepoint: UInt16?
        var state = EscapeParserState.None
        var offset = string.utf16.startIndex

        func finishEscape(range: Range<String.UTF16Index>, with control: UnicodeScalar) {
            priorCodepoint = nil
            state = .None
            guard let start = range.startIndex.samePositionIn(string.unicodeScalars), end = range.endIndex.samePositionIn(string.unicodeScalars) else {
                return
            }
            string.unicodeScalars.replaceRange(start ..< end, with: CollectionOfOne(control))
            offset = range.startIndex
        }

        while offset != string.utf16.endIndex {
            defer { offset = offset.successor() }

            switch (state, string.utf16[offset]) {
            case (.None, Escapes.Backslash), (.NeedSurrogatePair, Escapes.Backslash):
                state = .BeginControl(offset)
            case (.None, _):
                break

            case let (.BeginControl(escapeStart), Escapes.UnicodeEscapeStart):
                state = .UnicodeEscape(escapeStart, 0, remaining: 4)
            case (.BeginControl, _) where priorCodepoint != nil:
                throw Error.UnicodeEscapeInvalid(offset: start)
            case let (.BeginControl(escapeStart), next):
                guard let control = Escapes.controlFrom(next) else {
                    throw Error.ControlCharacterUnrecognized(offset: start)
                }

                finishEscape(escapeStart ... offset, with: control)

            case let (.UnicodeEscape(escapeStart, current, remaining), next):
                guard let codepoint = Escapes.hexFrom(next).map({ (current << 4) | $0 }) else {
                    throw Error.UnicodeEscapeInvalid(offset: start)
                }

                switch (remaining - 1, priorCodepoint) {
                case let (0, prior?):
                    finishEscape(escapeStart ... offset, with: Escapes.combineCodepoints(prior, codepoint))
                case (0, nil) where !UTF16.isLeadSurrogate(codepoint):
                    finishEscape(escapeStart ... offset, with: .init(codepoint))
                case (0, nil):
                    priorCodepoint = codepoint
                    state = .NeedSurrogatePair(escapeStart)
                case let (nextRemaining, _):
                    state = .UnicodeEscape(escapeStart, codepoint, remaining: nextRemaining)
                }

            case (.NeedSurrogatePair, _):
                throw Error.UnicodeEscapeInvalid(offset: start)
            }
        }
    }

}

// MARK: - Initializers

public extension JSONParser {

    init(utf8Data inData: NSData) {
        let data = inData.copy() as! NSData
        let buffer = UnsafeBufferPointer(start: UnsafePointer<UInt8>(data.bytes), count: data.length)
        self.init(buffer: buffer, owner: data)
    }

    init(string: String) {
        // don't want to include the nul termination in the buffer - trim it off
        let codePoints = string.nulTerminatedUTF8
        let buffer = codePoints.dropLast().withUnsafeBufferPointer { $0 }
        self.init(buffer: buffer, owner: codePoints)
    }

}

extension JSONParser: JSONParserType {

    public static func createJSONFromData(data: NSData) throws -> JSON {
        var parser = JSONParser(utf8Data: data)
        return try parser.parse()
    }

}

// MARK: - Errors

extension JSONParser {

    /// Enumeration describing possible errors that occur while parsing a JSON
    /// document. Most errors include an associated `offset`, representing the
    /// offset into the UTF-8 characters making up the document where the error
    /// occurred.
    public enum Error: ErrorType {
        /// The parser ran out of data prematurely. This usually means a value
        /// was not escaped, such as a string literal not ending with a double
        /// quote.
        case EndOfStreamUnexpected
        
        /// Unexpected non-whitespace data was left around `offset` after
        /// parsing all valid JSON.
        case EndOfStreamGarbage(offset: Int)
        
        /// Too many nested objects or arrays occured at the literal started
        /// around `offset`.
        case ExceededNestingLimit(offset: Int)
        
        /// A `character` was not a valid start of a value around `offset`.
        case ValueInvalid(offset: Int, character: UnicodeScalar)
        
        /// Badly-formed Unicode escape sequence at `offset`. A Unicode escape
        /// uses the text "\u" followed by 4 hex digits, such as "\uF09F\uA684"
        /// to represent U+1F984, "UNICORN FACE".
        case UnicodeEscapeInvalid(offset: Int)
        
        /// Badly-formed control character around `offset`. JSON supports
        /// backslash-escaped double quotes, slashes, whitespace control codes,
        /// and Unicode escape sequences.
        case ControlCharacterUnrecognized(offset: Int)
        
        /// Invalid token, expected `text` around `offset`
        case KeywordMisspelled(offset: Int, text: String)
        
        /// Badly-formed collection at given `offset`, expected `,` or `:`
        case CollectionMissingSeparator(offset: Int)
        
        /// While parsing an object literal, a value was found without a key
        /// around `offset`. The start of a string literal was expected.
        case DictionaryMissingKey(offset: Int)
        
        /// Badly-formed number with no digits around `offset`. After a decimal
        /// point, a number must include some number of digits.
        case NumberMissingFractionalDigits(offset: Int)
        
        /// Badly-formed number with symbols ("-" or "e") but no following
        /// digits around `offset`.
        case NumberSymbolMissingDigits(offset: Int)
    }

}