import 'dart:math' as math;

/// Hybrid crowd estimation (pure Dart, no Flutter/Firebase imports, easy to test).
///
/// score = confidence * live + (1 - confidence) * baseline
///  - baseline   : typical busyness for the hour of day / day of week (0..1)
///  - live       : recency-weighted average of student reports from the last 30 min (0..1)
///  - confidence : n / (n + 2), where n is the sum of report weights.
///                 One fresh report is not enough to overrule the baseline;
///                 several agreeing reports are.
enum CrowdLevel { low, medium, high }

class CrowdSample {
  final int level; // 1 = Low, 2 = Medium, 3 = High
  final DateTime createdAt;
  const CrowdSample(this.level, this.createdAt);
}

class CrowdEstimate {
  final CrowdLevel level;
  final double score;
  final double baseline;
  final double? live;
  final double confidence;
  final int reportsUsed;
  const CrowdEstimate({
    required this.level,
    required this.score,
    required this.baseline,
    required this.live,
    required this.confidence,
    required this.reportsUsed,
  });

  bool get usesLiveReports => reportsUsed > 0;
}

class CrowdEngine {
  static const Duration liveWindow = Duration(minutes: 30);
  static const double halfLifeMinutes = 10;
  static const double confidenceK = 2;
  static const double lowBelow = 0.34;
  static const double highFrom = 0.67;
  static const double weekendFactor = 0.2; // Friday and Saturday

  // Typical busyness per hour of the day (index = hour 0..23).
  // These are assumptions for a campus timetable; tune them with real data.
  static const List<double> _cafe = [
    0, 0, 0, 0, 0, 0, 0, // 00-06
    0.35, 0.6, 0.65, 0.55, 0.6, 0.7, 0.6, // 07-13
    0.4, 0.3, 0.25, 0.2, 0.15, 0.1, // 14-19
    0.05, 0.05, 0.05, 0.05, // 20-23
  ];
  static const List<double> _food = [
    0, 0, 0, 0, 0, 0, 0, // 00-06
    0.15, 0.25, 0.3, 0.4, 0.65, 0.9, 0.85, // 07-13
    0.6, 0.35, 0.25, 0.2, 0.15, 0.1, // 14-19
    0.05, 0.05, 0.05, 0.05, // 20-23
  ];

  static double baseline({
    required bool isCafe,
    required double popularity,
    required DateTime now,
  }) {
    final curve = isCafe ? _cafe : _food;
    final h = now.hour;
    final f = now.minute / 60.0;
    final a = curve[h];
    final b = curve[(h + 1) % 24];
    var v = a + (b - a) * f;
    final weekend =
        now.weekday == DateTime.friday || now.weekday == DateTime.saturday;
    if (weekend) v *= weekendFactor;
    return (v * popularity).clamp(0.0, 1.0).toDouble();
  }

  static CrowdEstimate estimate({
    required bool isCafe,
    required double popularity,
    required DateTime now,
    required List<CrowdSample> reports,
  }) {
    final base = baseline(isCafe: isCafe, popularity: popularity, now: now);

    double weightSum = 0;
    double weightedLevel = 0;
    int used = 0;
    for (final r in reports) {
      var ageMin = now.difference(r.createdAt).inSeconds / 60.0;
      if (ageMin < 0) ageMin = 0; // small clock differences
      if (ageMin > liveWindow.inMinutes) continue;
      final w = math.pow(0.5, ageMin / halfLifeMinutes).toDouble();
      weightSum += w;
      weightedLevel += w * (r.level.clamp(1, 3) - 1) / 2.0;
      used++;
    }

    double? live;
    double confidence = 0;
    double score = base;
    if (weightSum > 0) {
      live = weightedLevel / weightSum;
      confidence = weightSum / (weightSum + confidenceK);
      score = confidence * live + (1 - confidence) * base;
    }

    final level = score < lowBelow
        ? CrowdLevel.low
        : (score < highFrom ? CrowdLevel.medium : CrowdLevel.high);

    return CrowdEstimate(
      level: level,
      score: score,
      baseline: base,
      live: live,
      confidence: confidence,
      reportsUsed: used,
    );
  }
}
