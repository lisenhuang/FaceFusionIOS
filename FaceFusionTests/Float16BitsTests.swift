//
//  Float16BitsTests.swift
//  FaceFusionTests
//
//  The binary16 -> binary32 widening, kept as hand-rolled bit arithmetic even
//  though iOS is arm64 everywhere and `Float16` exists here: it is exactly
//  lossless, and it is the same implementation the macOS build validated.
//
//  Every model output that arrives as fp16 goes through this — inswapper hands
//  back fp16 tensors, and `emap` is stored as fp16 inside the graph — so an
//  error here is an error in every weight and every swapped pixel. A
//  plausible-looking one, too, since the exponent handling only goes wrong at
//  the ends of the range.
//

import Testing
import Foundation
@testable import FaceFusion

@Suite("Float16 widening")
struct Float16BitsTests {

    /// Expected values are the exact binary32 counterparts; binary16 has no
    /// value that binary32 cannot represent, so every one of these is exact
    /// and `==` is the right comparison.
    @Test func matchesKnownValues() {
        let cases: [(bits: UInt16, expected: Float)] = [
            (0x0000,  0.0),
            (0x3C00,  1.0),
            (0xBC00, -1.0),
            (0x4000,  2.0),
            (0xC500, -5.0),
            (0x3555,  0.333251953125),        // nearest half to 1/3
            (0x7BFF,  65504.0),               // largest normal
            (0x0400,  6.103515625e-05),       // smallest normal, 2^-14
            (0x03FF,  6.097555160522461e-05), // largest subnormal
            (0x0001,  5.960464477539063e-08), // smallest subnormal, 2^-24
        ]
        for item in cases {
            let actual = Float(float16Bits: item.bits)
            #expect(actual == item.expected,
                    "0x\(String(item.bits, radix: 16)) widened to \(actual), expected \(item.expected)")
        }
    }

    /// Signed zero has to stay signed: it is the one value where the sign bit
    /// is all that distinguishes two otherwise identical results.
    @Test func preservesSignedZero() {
        #expect(Float(float16Bits: 0x0000).sign == .plus)
        #expect(Float(float16Bits: 0x8000).sign == .minus)
        #expect(Float(float16Bits: 0x8000) == 0)
        #expect(Float(float16Bits: 0x8000).bitPattern == Float(-0.0).bitPattern)
    }

    @Test func widensInfinitiesAndNaN() {
        #expect(Float(float16Bits: 0x7C00) == .infinity)
        #expect(Float(float16Bits: 0xFC00) == -.infinity)
        #expect(Float(float16Bits: 0x7E00).isNaN)
        #expect(Float(float16Bits: 0xFE00).isNaN)
    }

    /// Subnormals are the case the naive implementation gets wrong: they carry
    /// no implicit leading 1, so they have to be renormalised rather than
    /// shifted into place. Each step of the subnormal ladder is exactly one
    /// unit of 2^-24.
    @Test func subnormalLadderIsLinear() {
        let unit: Float = 5.960464477539063e-08   // 2^-24
        for step in UInt16(1) ... 1023 {
            let actual = Float(float16Bits: step)
            #expect(actual == Float(step) * unit,
                    "subnormal 0x\(String(step, radix: 16)) widened to \(actual)")
        }
    }

    /// The subnormal path and the normal path have to meet exactly: the
    /// largest subnormal plus one unit is the smallest normal.
    @Test func subnormalsJoinNormalsWithoutAGap() {
        let largestSubnormal = Float(float16Bits: 0x03FF)
        let smallestNormal = Float(float16Bits: 0x0400)
        let unit: Float = 5.960464477539063e-08
        #expect(smallestNormal - largestSubnormal == unit)
    }

    /// Every normal exponent, walked end to end — this is what catches an
    /// off-by-one or an unsigned wrap in the rebiasing.
    @Test func everyNormalExponentRebiasesCorrectly() {
        for exponent in UInt16(1) ... 30 {
            let bits = exponent << 10                 // mantissa zero: a pure power of two
            let actual = Float(float16Bits: bits)
            let expected = exp2(Float(Int(exponent) - 15))
            #expect(actual == expected,
                    "exponent \(exponent) widened to \(actual), expected \(expected)")
        }
    }

    /// Negating the input must negate the output and change nothing else.
    @Test func signBitIsIndependentOfMagnitude() {
        for bits in stride(from: UInt16(1), through: 0x7BFF, by: 37) {
            let positive = Float(float16Bits: bits)
            let negative = Float(float16Bits: bits | 0x8000)
            #expect(negative == -positive, "0x\(String(bits, radix: 16))")
        }
    }

    /// The hardware type is available on this platform, so it can be used as an
    /// independent oracle — something the macOS build could not do, since a
    /// universal binary compiles an x86_64 slice where `Float16` does not exist.
    @Test func agreesWithHardwareFloat16() {
        for bits in stride(from: UInt16(0), through: 0x7BFF, by: 13) {
            let hardware = Float(Float16(bitPattern: bits))
            #expect(Float(float16Bits: bits) == hardware,
                    "0x\(String(bits, radix: 16))")
        }
    }
}
