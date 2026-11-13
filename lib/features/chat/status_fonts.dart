import 'package:flutter/material.dart';

/// One look someone can pick while writing a status. Built from fonts the
/// phone already has, so nothing extra is downloaded.
class StatusFontChoice {
  const StatusFontChoice(
    this.name,
    this.family,
    this.weight,
    this.style,
    this.letterSpacing,
  );

  final String name;
  final String? family;
  final FontWeight weight;
  final FontStyle style;
  final double letterSpacing;
}

const statusFontChoices = <StatusFontChoice>[
  StatusFontChoice('Classic', null, FontWeight.w700, FontStyle.normal, 0),
  StatusFontChoice('Light', null, FontWeight.w300, FontStyle.normal, 0.2),
  StatusFontChoice('Bold', null, FontWeight.w900, FontStyle.normal, 0),
  StatusFontChoice('Serif', 'serif', FontWeight.w600, FontStyle.normal, 0),
  StatusFontChoice('Italic', 'serif', FontWeight.w500, FontStyle.italic, 0.2),
  StatusFontChoice('Type', 'monospace', FontWeight.w500, FontStyle.normal, 0),
  StatusFontChoice('Narrow', 'sans-serif-condensed', FontWeight.w600, FontStyle.normal, 0),
  StatusFontChoice('Wide', null, FontWeight.w600, FontStyle.normal, 2.4),
  StatusFontChoice('Script', 'cursive', FontWeight.w500, FontStyle.italic, 0.3),
  StatusFontChoice('Casual', 'casual', FontWeight.w600, FontStyle.normal, 0.2),
  StatusFontChoice('Thin', 'sans-serif-thin', FontWeight.w200, FontStyle.normal, 0.4),
  StatusFontChoice('Medium', 'sans-serif-medium', FontWeight.w500, FontStyle.normal, 0),
  StatusFontChoice('Heavy', 'sans-serif-black', FontWeight.w900, FontStyle.normal, 0),
  StatusFontChoice('Soft', 'serif', FontWeight.w300, FontStyle.normal, 0.3),
  StatusFontChoice('Mono', 'monospace', FontWeight.w800, FontStyle.normal, 0),
  StatusFontChoice('Slim', 'sans-serif-condensed', FontWeight.w300, FontStyle.normal, -0.2),
  StatusFontChoice('Poster', null, FontWeight.w900, FontStyle.normal, 3),
  StatusFontChoice('Notes', 'serif', FontWeight.w400, FontStyle.italic, 0.4),
  StatusFontChoice('Marker', 'casual', FontWeight.w800, FontStyle.normal, 0.6),
  StatusFontChoice('Quiet', null, FontWeight.w400, FontStyle.normal, 0.8),
];

int statusFontIndex(int raw) {
  if (raw < 0 || raw >= statusFontChoices.length) return 0;
  return raw;
}

TextStyle statusFontStyle(
  int index, {
  required Color color,
  required double size,
}) {
  final pick = statusFontChoices[statusFontIndex(index)];
  return TextStyle(
    color: color,
    fontSize: size,
    fontFamily: pick.family,
    fontWeight: pick.weight,
    fontStyle: pick.style,
    letterSpacing: pick.letterSpacing,
    height: 1.25,
  );
}
