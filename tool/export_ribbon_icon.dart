// Resizes the glossy ribbon into the phone and PC icon files.
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as im;

const _bg = 0xFF000818;

void main(List<String> args) {
  final source = args.isEmpty
      ? r'C:\Users\TECNO\Downloads\Glossy Blue Ribbon Download Icon.png'
      : args.first;
  final raw = File(source).readAsBytesSync();
  final decoded = im.decodePng(raw);
  if (decoded == null) {
    stderr.writeln('Could not read $source');
    exit(1);
  }
  final cut = _dropBlack(decoded);
  final root = Directory.current.path;
  final master = _onDark(cut, 1024, 0.9);
  final foreground = _padded(cut, 1024, 0.72);
  final white = _silhouette(cut, 1024);

  void png(im.Image image, String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(im.encodePng(image, level: 6));
  }

  png(master, '$root/assets/brand/source_icon.png');
  png(master, '$root/assets/brand/icon_1024.png');
  png(foreground, '$root/assets/brand/icon_foreground_1024.png');
  png(_flat(_bg, 1024), '$root/assets/brand/icon_background_1024.png');
  png(master, '$root/assets/brand/icon_web_1024.png');
  png(_square(master, 512), '$root/assets/brand/icon_512.png');
  png(_square(master, 192), '$root/assets/brand/icon_192.png');

  const mip = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  const fg = {
    'mipmap-mdpi': 108,
    'mipmap-hdpi': 162,
    'mipmap-xhdpi': 216,
    'mipmap-xxhdpi': 324,
    'mipmap-xxxhdpi': 432,
  };
  const launch = {
    'mipmap-mdpi': 160,
    'mipmap-hdpi': 240,
    'mipmap-xhdpi': 320,
    'mipmap-xxhdpi': 480,
    'mipmap-xxxhdpi': 640,
  };
  const notice = {
    'drawable-mdpi': 24,
    'drawable-hdpi': 36,
    'drawable-xhdpi': 48,
    'drawable-xxhdpi': 72,
    'drawable-xxxhdpi': 96,
  };
  final android = '$root/android/app/src/main/res';
  for (final entry in mip.entries) {
    png(_square(foreground, entry.value), '$android/${entry.key}/ic_launcher.png');
    png(_square(foreground, entry.value), '$android/${entry.key}/ic_launcher_round.png');
    png(_square(white, entry.value), '$android/${entry.key}/ic_launcher_monochrome.png');
  }
  for (final entry in fg.entries) {
    png(_square(foreground, entry.value), '$android/${entry.key}/ic_launcher_foreground.png');
  }
  for (final entry in launch.entries) {
    png(_square(master, entry.value), '$android/${entry.key}/launch_image.png');
  }
  for (final entry in notice.entries) {
    png(_square(white, entry.value), '$android/${entry.key}/ic_notification.png');
  }
  png(_square(foreground, 192), '$android/drawable-nodpi/ic_notification_logo.png');

  png(_square(master, 32), '$root/web/favicon.png');
  png(_square(master, 192), '$root/web/icons/Icon-192.png');
  png(_square(master, 512), '$root/web/icons/Icon-512.png');
  png(_square(master, 192), '$root/web/icons/Icon-maskable-192.png');
  png(_square(master, 512), '$root/web/icons/Icon-maskable-512.png');
  png(_square(master, 512), '$root/backend/static/icon-512.png');
  if (File('$root/backend/webui/favicon.png').existsSync()) {
    png(_square(master, 32), '$root/backend/webui/favicon.png');
  }

  final ico = _ico([
    _square(master, 16),
    _square(master, 32),
    _square(master, 48),
    _square(master, 64),
    _square(master, 128),
    _square(master, 256),
  ]);
  File('$root/windows/runner/resources/app_icon.ico').writeAsBytesSync(ico);
  File('$root/assets/tray/app_icon.ico').writeAsBytesSync(ico);
  stdout.writeln('icons ${decoded.width}x${decoded.height} -> ribbon');
}

im.Image _dropBlack(im.Image source) {
  final image = im.Image.from(source);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      if (pixel.r < 22 && pixel.g < 22 && pixel.b < 22) {
        image.setPixelRgba(x, y, 0, 0, 0, 0);
      }
    }
  }
  return image;
}

im.Image _onDark(im.Image mark, int size, double fill) {
  final canvas = _flat(_bg, size);
  final inner = (size * fill).round();
  final scaled = im.copyResize(mark, width: inner, height: inner, interpolation: im.Interpolation.average);
  im.compositeImage(canvas, scaled, dstX: (size - inner) ~/ 2, dstY: (size - inner) ~/ 2);
  return canvas;
}

im.Image _padded(im.Image mark, int size, double fill) {
  final canvas = im.Image(width: size, height: size, numChannels: 4);
  final inner = (size * fill).round();
  final scaled = im.copyResize(mark, width: inner, height: inner, interpolation: im.Interpolation.average);
  im.compositeImage(canvas, scaled, dstX: (size - inner) ~/ 2, dstY: (size - inner) ~/ 2);
  return canvas;
}

im.Image _silhouette(im.Image mark, int size) {
  final fitted = _padded(mark, size, 0.72);
  for (var y = 0; y < fitted.height; y++) {
    for (var x = 0; x < fitted.width; x++) {
      final pixel = fitted.getPixel(x, y);
      if (pixel.a < 40) {
        fitted.setPixelRgba(x, y, 0, 0, 0, 0);
      } else {
        fitted.setPixelRgba(x, y, 255, 255, 255, 255);
      }
    }
  }
  return fitted;
}

im.Image _flat(int argb, int size) {
  final image = im.Image(width: size, height: size, numChannels: 4);
  final r = (argb >> 16) & 0xff;
  final g = (argb >> 8) & 0xff;
  final b = argb & 0xff;
  im.fill(image, color: im.ColorRgba8(r, g, b, 255));
  return image;
}

im.Image _square(im.Image image, int size) {
  return im.copyResize(image, width: size, height: size, interpolation: im.Interpolation.average);
}

Uint8List _ico(List<im.Image> images) {
  final pngs = [for (final image in images) im.encodePng(image, level: 6)];
  final header = 6 + 16 * pngs.length;
  var offset = header;
  final bytes = BytesBuilder();
  final head = ByteData(6);
  head.setUint16(0, 0, Endian.little);
  head.setUint16(2, 1, Endian.little);
  head.setUint16(4, pngs.length, Endian.little);
  bytes.add(head.buffer.asUint8List());
  for (var i = 0; i < pngs.length; i++) {
    final side = images[i].width;
    final entry = ByteData(16);
    entry.setUint8(0, side >= 256 ? 0 : side);
    entry.setUint8(1, side >= 256 ? 0 : side);
    entry.setUint8(2, 0);
    entry.setUint8(3, 0);
    entry.setUint16(4, 1, Endian.little);
    entry.setUint16(6, 32, Endian.little);
    entry.setUint32(8, pngs[i].length, Endian.little);
    entry.setUint32(12, offset, Endian.little);
    bytes.add(entry.buffer.asUint8List());
    offset += pngs[i].length;
  }
  for (final png in pngs) {
    bytes.add(png);
  }
  return bytes.toBytes();
}
