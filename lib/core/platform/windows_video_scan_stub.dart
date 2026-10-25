// Web build: the Windows Library scan needs dart:ffi, which a browser lacks.
const windowsVideoExtensions = {
  'mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', '3gp', 'wmv', 'flv', 'ts',
};

List<String> windowsDefaultVideoRoots() => const [];

({List<Map<String, Object?>> videos, Map<String, Object?> dirs}) scanWindowsVideoRoot(
  String root, [
  Map<String, Object?> remembered = const {},
]) => (videos: const <Map<String, Object?>>[], dirs: const <String, Object?>{});

String? windowsShellThumbnail(String path, String outPath, int size) => null;
