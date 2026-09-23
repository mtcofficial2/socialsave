/// A published app version, compared as major.minor.patch.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static ReleaseVersion? parse(String raw) {
    final cleaned = raw.trim().replaceFirst(RegExp(r'^v', caseSensitive: false), '');
    final core = cleaned.split('+').first.split('-').first;
    if (core.isEmpty) return null;
    final parts = core.split('.');
    if (parts.isEmpty || int.tryParse(parts.first) == null) return null;
    int at(int index) => index < parts.length ? int.tryParse(parts[index]) ?? 0 : 0;
    return ReleaseVersion(at(0), at(1), at(2));
  }

  @override
  int compareTo(ReleaseVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  String toString() => '$major.$minor.$patch';
}

/// The release the installed app should offer, if it is newer.
class AvailableUpdate {
  const AvailableUpdate({required this.version, required this.downloadUrl});

  final String version;
  final Uri downloadUrl;
}

AvailableUpdate? newerRelease({
  required String current,
  required String tag,
  String? apkUrl,
  String? pageUrl,
}) {
  final installed = ReleaseVersion.parse(current);
  final latest = ReleaseVersion.parse(tag);
  if (installed == null || latest == null || !(latest > installed)) return null;
  final raw = (apkUrl != null && apkUrl.isNotEmpty) ? apkUrl : pageUrl;
  final uri = raw == null ? null : Uri.tryParse(raw);
  if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) return null;
  return AvailableUpdate(version: latest.toString(), downloadUrl: uri);
}
