/// One inclusive byte span. Ranges from [planByteRanges] do not overlap.
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;

  String get header => 'bytes=$start-$end';
}

/// Splits [length] into at most [parts] contiguous ranges that cover every byte once.
List<ByteRange> planByteRanges(int length, int parts) {
  if (length <= 0 || parts <= 0) return const [];
  final chunk = (length / parts).ceil();
  final ranges = <ByteRange>[];
  for (var part = 0; part < parts; part++) {
    final start = part * chunk;
    if (start >= length) break;
    var end = start + chunk - 1;
    if (end >= length) end = length - 1;
    ranges.add(ByteRange(start, end));
  }
  return ranges;
}

/// The total size declared by a Content-Range header, if the range matches the request.
int? contentRangeTotal(String? header, int start, int end) {
  if (header == null) return null;
  final match = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)').firstMatch(header);
  if (match == null) return null;
  final gotStart = int.tryParse(match.group(1)!);
  final gotEnd = int.tryParse(match.group(2)!);
  if (gotStart != start || gotEnd != end) return null;
  if (match.group(3) == '*') return null;
  return int.tryParse(match.group(3)!);
}
