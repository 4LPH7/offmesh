/// Sliding window over received transport counters.
///
/// Accepts each counter at most once. Counters more than [size] below the highest one
/// seen are refused, so the set of remembered counters stays bounded. Reordering inside
/// the window is tolerated; a lost counter just stays unused.
class ReplayWindow {
  ReplayWindow({this.size = 1024});

  final int size;
  int _highest = -1;
  final Set<int> _seen = {};

  bool accepts(int counter) =>
      counter > _highest - size && !_seen.contains(counter);

  /// Records [counter]. Returns false, changing nothing, if it is a replay or too old.
  bool accept(int counter) {
    if (!accepts(counter)) return false;
    _seen.add(counter);
    if (counter > _highest) {
      _highest = counter;
      _seen.removeWhere((seen) => seen <= _highest - size);
    }
    return true;
  }
}
