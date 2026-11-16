import 'package:flutter_test/flutter_test.dart';
import 'package:qoot/crowd_engine.dart'; // change "qoot" to the name in your pubspec.yaml

void main() {
  // 2026-10-25 is a Sunday, 2026-10-23 is a Friday.
  final sundayNoon = DateTime(2026, 10, 25, 12, 0);
  final sunday3am = DateTime(2026, 10, 25, 3, 0);
  final fridayNoon = DateTime(2026, 10, 23, 12, 0);

  CrowdEstimate est(
    DateTime now, {
    bool isCafe = false,
    List<CrowdSample> reports = const [],
  }) => CrowdEngine.estimate(
    isCafe: isCafe,
    popularity: 1.0,
    now: now,
    reports: reports,
  );

  test('baseline: lunch rush at a restaurant is High', () {
    expect(est(sundayNoon).level, CrowdLevel.high);
  });

  test('baseline: night time is Low', () {
    expect(est(sunday3am, isCafe: true).level, CrowdLevel.low);
  });

  test('baseline: Friday is quiet', () {
    expect(est(fridayNoon).level, CrowdLevel.low);
  });

  test('three fresh "Low" reports pull a High baseline down to Medium', () {
    final reports = List.generate(3, (_) => CrowdSample(1, sundayNoon));
    final e = est(sundayNoon, reports: reports);
    expect(e.level, CrowdLevel.medium);
    expect(e.usesLiveReports, true);
  });

  test('one single "High" report is not enough to overrule a quiet baseline', () {
    final e = est(sunday3am, isCafe: true, reports: [CrowdSample(3, sunday3am)]);
    expect(e.level, CrowdLevel.low);
  });

  test('two fresh "High" reports raise a quiet baseline to Medium', () {
    final e = est(
      sunday3am,
      isCafe: true,
      reports: [CrowdSample(3, sunday3am), CrowdSample(3, sunday3am)],
    );
    expect(e.level, CrowdLevel.medium);
  });

  test('reports older than 30 minutes are ignored', () {
    final old = sundayNoon.subtract(const Duration(minutes: 31));
    final e = est(sundayNoon, reports: [CrowdSample(1, old), CrowdSample(1, old)]);
    expect(e.usesLiveReports, false);
    expect(e.level, CrowdLevel.high);
  });
}
