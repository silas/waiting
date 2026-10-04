import Foundation

/// The lines in the last `length` bytes of a file, without the partial line the tail starts in.
/// Nil if the file can't be read.
nonisolated func tailLines(of url: URL, length: Int = 1 << 20) -> [Data.SubSequence]? {
  guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
  defer { try? handle.close() }
  guard let size = try? handle.seekToEnd() else { return nil }
  // One byte before the tail too, to tell whether the tail starts at the beginning of a line.
  let start = size > UInt64(length) ? size - UInt64(length) - 1 : 0
  guard (try? handle.seek(toOffset: start)) != nil,
    var data = try? handle.readToEnd()
  else { return nil }

  if start > 0 {
    // Drop everything up to the first line break: the partial line, or just the byte before a
    // tail that starts on a line boundary.
    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
    data = data[data.index(after: newline)...]
  }
  return data.split(separator: UInt8(ascii: "\n"))
}
