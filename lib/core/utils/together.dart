/// How many links are looked up at once. Each one starts downloading as
/// soon as it is ready, so the rest join without waiting for a finished file.
const int saveAtOnce = 4;

/// Runs [work] on up to [saveAtOnce] items at the same time, in order.
Future<void> runTogether<T>(
  Iterable<T> items,
  Future<void> Function(T item) work,
) async {
  final list = items.toList();
  if (list.isEmpty) return;
  var next = 0;
  Future<void> worker() async {
    while (true) {
      if (next >= list.length) return;
      final item = list[next];
      next++;
      await work(item);
    }
  }

  final n = list.length < saveAtOnce ? list.length : saveAtOnce;
  await Future.wait([for (var i = 0; i < n; i++) worker()]);
}
