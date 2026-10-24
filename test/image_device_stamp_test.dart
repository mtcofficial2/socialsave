import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/library/image_device_stamp.dart';

void main() {
  test('a jpeg from elsewhere names this device and keeps the picture', () {
    final xmp = 'http://ns.adobe.com/xap/1.0/\x00<creator>internet</creator>';
    final xmpLen = xmp.length + 2;
    final original = Uint8List.fromList([
      0xFF, 0xD8,
      0xFF, 0xE0, 0x00, 0x10,
      ...'JFIF\x00'.codeUnits, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
      0xFF, 0xE1, (xmpLen >> 8) & 0xFF, xmpLen & 0xFF,
      ...xmp.codeUnits,
      0xFF, 0xED, 0x00, 0x08,
      ...'IPTC!!'.codeUnits,
      0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x7F,
      0xFF, 0xD9,
    ]);

    final stamped = stampJpeg(
      original,
      make: 'SHARP',
      model: 'A202SH',
      captured: DateTime.utc(2026, 10, 22, 12, 30, 15),
    );
    final camera = readJpegCamera(stamped);

    expect(camera.make, 'SHARP');
    expect(camera.model, 'A202SH');
    expect(camera.orientation, 1);
    expect(String.fromCharCodes(stamped), contains('JFIF'));
    expect(String.fromCharCodes(stamped), isNot(contains('internet')));
    expect(String.fromCharCodes(stamped), isNot(contains('IPTC!!')));
    expect(stamped.first, 0xFF);
    expect(stamped[1], 0xD8);
    expect(stamped[stamped.length - 2], 0xFF);
    expect(stamped.last, 0xD9);
    expect(stamped.sublist(stamped.length - 3, stamped.length - 2).single, 0x7F);
  });

  test('a turned photo stays turned', () {
    final first = stampJpeg(
      Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0x00, 0xFF, 0xD9]),
      make: 'Other',
      model: 'Camera',
    );
    final tag = [0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00];
    final at = _indexOf(first, tag);
    expect(at, greaterThan(0));
    final turned = Uint8List.fromList(first);
    turned[at + 8] = 6;

    final stamped = stampJpeg(turned, make: 'SHARP', model: 'A202SH');
    expect(readJpegCamera(stamped).orientation, 6);
    expect(readJpegCamera(stamped).make, 'SHARP');
  });

  test('a short camera name is stored in the entry itself', () {
    final stamped = stampJpeg(
      Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0x00, 0xFF, 0xD9]),
      make: 'PC',
      model: 'A',
    );
    final camera = readJpegCamera(stamped);
    expect(camera.make, 'PC');
    expect(camera.model, 'A');
  });

  test('a file that is not a jpeg is refused', () {
    expect(
      () => stampJpeg(Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]), make: 'SHARP', model: 'A202SH'),
      throwsFormatException,
    );
  });
}

int _indexOf(Uint8List bytes, List<int> needle) {
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var same = true;
    for (var n = 0; n < needle.length; n++) {
      if (bytes[i + n] != needle[n]) {
        same = false;
        break;
      }
    }
    if (same) return i;
  }
  return -1;
}
