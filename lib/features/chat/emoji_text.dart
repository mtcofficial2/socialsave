/// True when [raw] is only emoji, the way a Telegram message drops its bubble.
bool emojiOnlyText(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return false;
  return _scanEmoji(text) > 0;
}

/// How many emoji are in [raw]. Zero when the text is not emoji-only.
int emojiClusterCount(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return 0;
  final count = _scanEmoji(text);
  if (count > 24) return 0;
  return count;
}

/// A short run of emoji is drawn large. A longer run stays readable.
double emojiOnlySize(int count) {
  if (count <= 1) return 48;
  if (count == 2) return 40;
  if (count == 3) return 34;
  return 28;
}

/// Positive when every character is an emoji piece. Zero otherwise.
int _scanEmoji(String text) {
  final runes = text.runes.toList();
  if (runes.isEmpty || runes.length > 80) return 0;
  var count = 0;
  for (var i = 0; i < runes.length; i++) {
    final rune = runes[i];
    if (rune == 0x20 || rune == 0x0A || rune == 0x200D || rune == 0xFE0F || rune == 0xFE0E) {
      continue;
    }
    if (rune >= 0x1F3FB && rune <= 0x1F3FF) continue;
    if (rune == 0x20E3) continue;
    if (rune == 0x23 || rune == 0x2A || (rune >= 0x30 && rune <= 0x39)) {
      if (!runes.skip(i + 1).contains(0x20E3)) return 0;
      count++;
      continue;
    }
    if (_pictograph(rune)) {
      count++;
      continue;
    }
    return 0;
  }
  if (count > 24) return 0;
  return count;
}

bool _pictograph(int rune) {
  if (rune >= 0x1F1E6 && rune <= 0x1F1FF) return true;
  if (rune >= 0x1F300 && rune <= 0x1FAFF) return true;
  if (rune >= 0x2600 && rune <= 0x27BF) return true;
  if (rune >= 0x231A && rune <= 0x231B) return true;
  if (rune >= 0x23E9 && rune <= 0x23FA) return true;
  if (rune >= 0x25AA && rune <= 0x25FE) return true;
  if (rune >= 0x2934 && rune <= 0x2935) return true;
  if (rune >= 0x2B05 && rune <= 0x2B07) return true;
  if (rune == 0x00A9 ||
      rune == 0x00AE ||
      rune == 0x203C ||
      rune == 0x2049 ||
      rune == 0x2122 ||
      rune == 0x2139 ||
      rune == 0x2194 ||
      rune == 0x2195 ||
      rune == 0x2196 ||
      rune == 0x2197 ||
      rune == 0x2198 ||
      rune == 0x2199 ||
      rune == 0x21A9 ||
      rune == 0x21AA ||
      rune == 0x2328 ||
      rune == 0x24C2 ||
      rune == 0x2B1B ||
      rune == 0x2B1C ||
      rune == 0x2B50 ||
      rune == 0x2B55 ||
      rune == 0x3030 ||
      rune == 0x303D ||
      rune == 0x3297 ||
      rune == 0x3299) {
    return true;
  }
  return false;
}
