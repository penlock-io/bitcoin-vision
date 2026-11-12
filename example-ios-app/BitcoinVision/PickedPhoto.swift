import Foundation

/**
 * A photo a person picks out of their library comes from anywhere: a
 * cloud library, a scanner app, a screenshot. The camera's photos are a
 * few megabytes; this is the point past which the file is not a
 * photograph of a page and is not worth holding in memory twice.
 */
let PICKED_PHOTO_LIMIT = 32 * 1024 * 1024

/**
 * Up to [limit] bytes of [input], or nil if it holds more. The stream
 * is never read into memory past the limit, so an enormous document
 * costs one buffer rather than the phone. The caller opens and closes it.
 */
func readAtMost(input: InputStream, limit: Int = PICKED_PHOTO_LIMIT) -> Data? {
    precondition(limit > 0)
    var out = Data()
    let size = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: size)
    while true {
        let read = input.read(&buffer, maxLength: size)
        if read < 0 { return nil } // A stream error: nothing trustworthy was read.
        if read == 0 { return out }
        if out.count + read > limit { return nil }
        out.append(buffer, count: read)
    }
}

// The Android app's `onEmulator` gates a debug fixture route that reads a
// directory only adb can fill; it has no iOS counterpart and is not ported.
