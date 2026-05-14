import 'dart:math';

class RateLimiter {
  RateLimiter({this.callsPerSecond = 0.5})
    : _intervalMs = (1000 / callsPerSecond).round();

  final double callsPerSecond;
  final int _intervalMs;
  final _lastMs = <String, int>{};
  final _backoffMs = <String, int>{};
  final _rng = Random();

  Future<void> wait(String domain) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final backoff = _backoffMs[domain] ?? 0;
    final elapsed = now - (_lastMs[domain] ?? 0);
    final target = (_intervalMs > backoff ? _intervalMs : backoff);
    final gap = target - elapsed;
    if (gap > 0) {
      final jitter = 50 + _rng.nextInt(150);
      await Future<void>.delayed(Duration(milliseconds: gap + jitter));
    }
    _lastMs[domain] = DateTime.now().millisecondsSinceEpoch;
  }

  void penalize(String domain) {
    final current = _backoffMs[domain] ?? _intervalMs;
    var next = current * 2;
    if (next > 60000) {
      next = 60000;
    }
    _backoffMs[domain] = next;
  }

  void reset(String domain) {
    final current = _backoffMs[domain];
    if (current == null) return;
    var next = (current * 0.75).round();
    if (next < _intervalMs) {
      next = _intervalMs;
    }
    _backoffMs[domain] = next;
  }
}
