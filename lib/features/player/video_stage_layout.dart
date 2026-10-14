/// Where the picture and the control band sit in the player.
///
/// The control band is the black area directly under the picture. It never
/// covers the picture, for a wide video or a tall one.
class VideoStageLayout {
  const VideoStageLayout({
    required this.videoLeft,
    required this.videoTop,
    required this.videoWidth,
    required this.videoHeight,
    required this.dockTop,
    required this.dockHeight,
  });

  final double videoLeft;
  final double videoTop;
  final double videoWidth;
  final double videoHeight;
  final double dockTop;
  final double dockHeight;

  static const dockHeightDefault = 128.0;

  factory VideoStageLayout.compute({
    required double maxWidth,
    required double maxHeight,
    required double aspect,
    double dockHeight = dockHeightDefault,
  }) {
    final room = (maxHeight - dockHeight).clamp(0.0, maxHeight);
    final safeAspect = aspect > 0 ? aspect : 9 / 16;
    var videoWidth = maxWidth;
    var videoHeight = videoWidth / safeAspect;
    if (videoHeight > room) {
      videoHeight = room;
      videoWidth = videoHeight * safeAspect;
    }
    final spare = maxHeight - videoHeight - dockHeight;
    final top = spare > 0 ? spare / 2 : 0.0;
    return VideoStageLayout(
      videoLeft: (maxWidth - videoWidth) / 2,
      videoTop: top,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      dockTop: top + videoHeight,
      dockHeight: dockHeight,
    );
  }

  bool get controlsClearOfPicture => dockTop + 0.01 >= videoTop + videoHeight;
}
