/// Why a running save should wait, or null when the phone can keep saving.
///
/// Charging is checked first. A low battery does not pause a save that is
/// already on a charger. An unknown phone state never blocks a save.
String? powerHoldReason({
  required bool onlyWhileCharging,
  required bool pauseBelowBattery,
  required bool pocketPause,
  required bool known,
  required int battery,
  required bool charging,
  required bool pocket,
}) {
  if (!known) return null;
  if (onlyWhileCharging && !charging) {
    return 'Waiting until the phone is charging.';
  }
  if (pauseBelowBattery && battery >= 0 && battery < 15 && !charging) {
    return 'Paused below 15% battery.';
  }
  if (pocketPause && pocket) {
    return 'Paused while the phone is face down.';
  }
  return null;
}
