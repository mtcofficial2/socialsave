import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/player/video_stage_layout.dart';

void main() {
  test('landscape video keeps the controls in the black band under it', () {
    final layout = VideoStageLayout.compute(
      maxWidth: 400,
      maxHeight: 700,
      aspect: 16 / 9,
    );

    expect(layout.videoWidth, 400);
    expect(layout.videoHeight, closeTo(225, 0.01));
    expect(layout.dockTop, closeTo(layout.videoTop + layout.videoHeight, 0.01));
    expect(layout.controlsClearOfPicture, isTrue);
    expect(layout.dockTop + layout.dockHeight, lessThanOrEqualTo(700));
  });

  test('portrait video shrinks so the controls stay under the picture', () {
    final layout = VideoStageLayout.compute(
      maxWidth: 400,
      maxHeight: 700,
      aspect: 9 / 16,
    );

    expect(
      layout.videoHeight,
      closeTo(700 - VideoStageLayout.dockHeightDefault, 0.01),
    );
    expect(layout.videoWidth, lessThan(400));
    expect(layout.videoLeft, greaterThan(0));
    expect(layout.dockTop, closeTo(layout.videoTop + layout.videoHeight, 0.01));
    expect(layout.controlsClearOfPicture, isTrue);
  });

  test('landscape screen still leaves the control band under the picture', () {
    final layout = VideoStageLayout.compute(
      maxWidth: 800,
      maxHeight: 360,
      aspect: 16 / 9,
    );

    expect(
      layout.videoHeight,
      closeTo(360 - VideoStageLayout.dockHeightDefault, 0.01),
    );
    expect(layout.videoWidth, lessThan(800));
    expect(layout.dockTop, closeTo(layout.videoTop + layout.videoHeight, 0.01));
    expect(layout.controlsClearOfPicture, isTrue);
  });
}
