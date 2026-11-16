# Qoot-قوت  — Smart Campus Dining & Crowd Tracker

**Qoot** is a cross-platform mobile application built with Flutter designed to enhance the campus dining experience. It enables students to explore campus restaurants and cafes, browse full menus, check real-time crowd levels, and discover smart dining recommendations.

---

## ✨ Key Features

* **Real-Time Crowd Estimation:** Uses a hybrid statistical engine (`crowd_engine.dart`) combining live, recency-weighted student reports with historical hourly/daily baselines to display accurate crowd levels (**Low**, **Medium**, **High**).
* **Campus Dining Directory:** Comprehensive listings of on-campus restaurants and cafes with detailed menus and pricing.
* **Smart Recommendations:** Personalized dining suggestions tailored to user preferences and current crowd conditions.
* **Clean Modern UI:** Built with a responsive interface styled using **Plus Jakarta Sans** typography.
* **Cloud Sync:** Powered by Firebase for real-time crowd reporting and dynamic data updates.

---

## 🛠️ Tech Stack

* **Framework:** Flutter & Dart
* **Backend & Database:** Firebase (Cloud Firestore / Firebase Core)
* **Architecture:** Modular separation between UI (`main.dart`), static/catalog data (`data.dart`), and pure Dart business logic (`crowd_engine.dart`) with unit testing (`crowd_engine_test.dart`).

---
