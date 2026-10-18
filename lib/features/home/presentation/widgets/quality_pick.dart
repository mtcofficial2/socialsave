import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';

int? _heightOf(MediaFormat f) {
  final m = RegExp(r'(\d{3,4})p').firstMatch(f.displayQuality.toLowerCase());
  return m == null ? null : int.tryParse(m.group(1)!);
}

bool _isAudio(MediaFormat f) => !f.hasVideo || f.quality.toLowerCase() == 'audio';

/// One choice per distinct quality: Auto/Original first, then 1080p, 720p...,
/// audio-only last. The first format of each quality wins.
List<MediaFormat> qualityChoices(MediaInfo m) {
  final seen = <String>{};
  final out = <MediaFormat>[];
  for (final f in m.formats) {
    if (seen.add(f.displayQuality.toLowerCase())) out.add(f);
  }
  int rank(MediaFormat f) {
    if (_isAudio(f)) return 100000;
    final h = _heightOf(f);
    return h == null ? -1 : 50000 - h;
  }

  out.sort((a, b) => rank(a).compareTo(rank(b)));
  return out;
}

/// The heights offered (for the floating card) and whether audio-only exists.
({List<int> heights, bool audio}) qualitySummary(MediaInfo m) {
  final hs = <int>{};
  var audio = false;
  for (final f in m.formats) {
    if (_isAudio(f)) {
      audio = true;
    } else {
      final h = _heightOf(f);
      if (h != null) hs.add(h);
    }
  }
  return (heights: hs.toList()..sort((a, b) => b.compareTo(a)), audio: audio);
}

/// Maps the floating card's choice (best, 1080, 720, 480, audio) to a real format:
/// the best one at or below the wanted height, else the closest above.
MediaFormat? pickFormat(MediaInfo m, String pref) {
  if (pref == 'best') return m.defaultFormat;
  if (pref == 'audio') {
    for (final f in m.formats) {
      if (_isAudio(f)) return f;
    }
    return m.defaultFormat;
  }
  final want = int.tryParse(pref);
  if (want == null) return m.defaultFormat;
  MediaFormat? below, above;
  var belowH = -1, aboveH = 1 << 30;
  for (final f in m.formats) {
    if (_isAudio(f)) continue;
    final h = _heightOf(f);
    if (h == null) continue;
    if (h <= want && h > belowH) {
      below = f;
      belowH = h;
    }
    if (h > want && h < aboveH) {
      above = f;
      aboveH = h;
    }
  }
  return below ?? above ?? m.defaultFormat;
}
