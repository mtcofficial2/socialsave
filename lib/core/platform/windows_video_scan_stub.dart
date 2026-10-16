// Web build: the Windows Library scan needs dart:ffi, which a browser lacks.
const windowsVideoExtensions = {
  'mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', '3gp', 'wmv', 'flv', 'ts',
};

List<String> windowsDefaultVideoRoots() => const [];

List<Map<String, Object?>> scanWindowsVideoRoot(String root) => const [];

String? windowsShellThumbnail(String path, String outPath, int size) => null;
