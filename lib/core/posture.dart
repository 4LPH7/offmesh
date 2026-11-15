/// What the phone may transmit. See docs/mission_plan.md section 4.6.
///
/// Silent: no sockets, no UDP, no advertising, no connections; passive reception only.
/// Quiet: no beacons or advertisements and no beacon-triggered dials. Links that are
/// already open stay up, and their keepalives, receipts and relays still transmit.
/// Normal: discovery, dialing and relaying run.
enum Posture { silent, quiet, normal }

/// The posture every transport consults before it transmits. Persistence lives in
/// lib/app/posture_store.dart; this class only holds the value in memory.
class PostureController {
  PostureController([Posture initial = Posture.normal]) : _current = initial;

  Posture _current;

  Posture get current => _current;

  void change(Posture next) => _current = next;
}
