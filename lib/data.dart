import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crowd_engine.dart';

// ============================================================
// MODELS
// ============================================================
class Restaurant {
  final String id;
  final String name;
  final String category; // 'Cafes' | 'Restaurants'
  final String logoUrl;
  final String bannerUrl;
  final String priceRange;
  final String walkTime;
  final String hours;
  final String buildingLocation;
  final double latitude;
  final double longitude;
  final bool isOpen;
  final double popularity; // used by the crowd baseline (0.5 - 1.2)
  final int order;

  const Restaurant({
    required this.id,
    required this.name,
    required this.category,
    required this.logoUrl,
    required this.bannerUrl,
    required this.priceRange,
    required this.walkTime,
    required this.hours,
    required this.buildingLocation,
    required this.latitude,
    required this.longitude,
    this.isOpen = true,
    this.popularity = 1.0,
    this.order = 0,
  });

  bool get isCafe => category == 'Cafes';

  factory Restaurant.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return Restaurant(
      id: doc.id,
      name: d['name'] ?? '',
      category: d['category'] ?? 'Restaurants',
      logoUrl: d['logoUrl'] ?? '',
      bannerUrl: d['bannerUrl'] ?? '',
      priceRange: d['priceRange'] ?? r'$$',
      walkTime: d['walkTime'] ?? '',
      hours: d['hours'] ?? '',
      buildingLocation: d['buildingLocation'] ?? '',
      latitude: (d['latitude'] ?? 0).toDouble(),
      longitude: (d['longitude'] ?? 0).toDouble(),
      isOpen: d['isOpen'] ?? true,
      popularity: (d['popularity'] ?? 1.0).toDouble(),
      order: (d['order'] ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'category': category,
    'logoUrl': logoUrl,
    'bannerUrl': bannerUrl,
    'priceRange': priceRange,
    'walkTime': walkTime,
    'hours': hours,
    'buildingLocation': buildingLocation,
    'latitude': latitude,
    'longitude': longitude,
    'isOpen': isOpen,
    'popularity': popularity,
    'order': order,
  };
}

class MenuItem {
  final String id;
  final String restaurantId;
  final String name;
  final String description;
  final double price;
  final int calories;
  final String imageUrl;
  final bool isAvailable;
  final double ratingSum;
  final int ratingCount;

  const MenuItem({
    required this.id,
    required this.restaurantId,
    required this.name,
    this.description = '',
    required this.price,
    this.calories = 0,
    this.imageUrl = '',
    this.isAvailable = true,
    this.ratingSum = 0,
    this.ratingCount = 0,
  });

  double get averageRating => ratingCount == 0 ? 0 : ratingSum / ratingCount;

  factory MenuItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return MenuItem(
      id: doc.id,
      restaurantId: d['restaurantId'] ?? '',
      name: d['name'] ?? '',
      description: d['description'] ?? '',
      price: (d['price'] ?? 0).toDouble(),
      calories: (d['calories'] ?? 0).toInt(),
      imageUrl: d['imageUrl'] ?? '',
      isAvailable: d['isAvailable'] ?? true,
      ratingSum: (d['ratingSum'] ?? 0).toDouble(),
      ratingCount: (d['ratingCount'] ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
    'restaurantId': restaurantId,
    'name': name,
    'description': description,
    'price': price,
    'calories': calories,
    'imageUrl': imageUrl,
    'isAvailable': isAvailable,
    'ratingSum': ratingSum,
    'ratingCount': ratingCount,
  };
}

class PopularMeal {
  final Restaurant restaurant;
  final MenuItem item;
  final double score;
  const PopularMeal(this.restaurant, this.item, this.score);
}

// ============================================================
// STORE (listens to Firestore and exposes ready-to-use data)
// ============================================================
class CampusStore extends ChangeNotifier {
  final _db = FirebaseFirestore.instance;

  List<Restaurant> restaurants = [];
  List<MenuItem> items = [];
  List<_RawCrowd> _crowd = [];
  bool loaded = false;
  String? error;

  final List<StreamSubscription> _subs = [];
  Timer? _tick;
  String? _deviceId;

  void start() {
    _subs.add(
      _db.collection('restaurants').orderBy('order').snapshots().listen(
        (snap) {
          restaurants = snap.docs.map(Restaurant.fromDoc).toList();
          loaded = true;
          error = null;
          notifyListeners();
        },
        onError: _onError,
      ),
    );
    // All menu items of all restaurants (collection group, no filter needed).
    _subs.add(
      _db.collectionGroup('menu').snapshots().listen((snap) {
        items = snap.docs.map(MenuItem.fromDoc).toList();
        notifyListeners();
      }, onError: _onError),
    );
    _subs.add(
      _db
          .collection('crowdReports')
          .orderBy('createdAt', descending: true)
          .limit(300)
          .snapshots()
          .listen((snap) {
            _crowd = snap.docs.map((d) {
              final m = d.data();
              return _RawCrowd(
                m['restaurantId'] ?? '',
                (m['level'] ?? 2).toInt(),
                (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
              );
            }).toList();
            notifyListeners();
          }, onError: _onError),
    );
    // Crowd depends on the clock, so refresh every minute.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => notifyListeners());
  }

  void _onError(Object e) {
    error = e.toString();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _tick?.cancel();
    super.dispose();
  }

  // ---------- read helpers ----------
  Restaurant? restaurantById(String id) {
    for (final r in restaurants) {
      if (r.id == id) return r;
    }
    return null;
  }

  List<MenuItem> menuOf(String restaurantId) {
    final list = items.where((i) => i.restaurantId == restaurantId).toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// Average of the restaurant's rated dishes (null when nothing is rated yet).
  double? restaurantRating(String restaurantId) {
    double sum = 0;
    int count = 0;
    for (final i in items) {
      if (i.restaurantId == restaurantId) {
        sum += i.ratingSum;
        count += i.ratingCount;
      }
    }
    return count == 0 ? null : sum / count;
  }

  CrowdEstimate crowdFor(Restaurant r) {
    return CrowdEngine.estimate(
      isCafe: r.isCafe,
      popularity: r.popularity,
      now: DateTime.now(),
      reports: _crowd
          .where((c) => c.restaurantId == r.id)
          .map((c) => CrowdSample(c.level, c.createdAt))
          .toList(),
    );
  }

  /// Popular meals ranked by a smoothed rating:
  /// (C * priorMean + sum of stars) / (C + number of ratings).
  /// Dishes with fewer than [minRatings] ratings are not ranked.
  List<PopularMeal> popular({int limit = 8, int minRatings = 3}) {
    const prior = 4.0;
    const c = 5.0;
    final list = <PopularMeal>[];
    for (final it in items) {
      if (it.ratingCount < minRatings || !it.isAvailable) continue;
      final r = restaurantById(it.restaurantId);
      if (r == null) continue;
      final score = (c * prior + it.ratingSum) / (c + it.ratingCount);
      list.add(PopularMeal(r, it, score));
    }
    list.sort((a, b) => b.score.compareTo(a.score));
    return list.take(limit).toList();
  }

  // ---------- anonymous device id (one rating per device per dish) ----------
  Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('deviceId');
    if (id == null) {
      id =
          '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 31)}';
      await prefs.setString('deviceId', id);
    }
    _deviceId = id;
    return id;
  }

  DocumentReference<Map<String, dynamic>> _itemRef(MenuItem i) => _db
      .collection('restaurants')
      .doc(i.restaurantId)
      .collection('menu')
      .doc(i.id);

  // ---------- student actions (return null on success, else an error text) ----------
  Future<String?> rateItem(MenuItem item, int stars) async {
    try {
      final device = await deviceId();
      final ratingRef = _db.collection('ratings').doc('${item.id}_$device');
      final itemRef = _itemRef(item);
      await _db.runTransaction((tx) async {
        final old = await tx.get(ratingRef);
        final itemSnap = await tx.get(itemRef);
        final data = itemSnap.data() ?? {};
        double sum = (data['ratingSum'] ?? 0).toDouble();
        int count = (data['ratingCount'] ?? 0).toInt();
        if (old.exists) {
          sum += stars - (old.data()?['stars'] ?? 0).toInt();
        } else {
          sum += stars;
          count += 1;
        }
        tx.set(ratingRef, {
          'itemId': item.id,
          'restaurantId': item.restaurantId,
          'deviceId': device,
          'stars': stars,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        tx.update(itemRef, {'ratingSum': sum, 'ratingCount': count});
      });
      return null;
    } catch (e) {
      return 'Could not save your rating: $e';
    }
  }

  Future<String?> reportUnavailable(MenuItem item) async {
    try {
      final device = await deviceId();
      final batch = _db.batch();
      batch.set(_db.collection('unavailableReports').doc(), {
        'itemId': item.id,
        'restaurantId': item.restaurantId,
        'deviceId': device,
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.update(_itemRef(item), {
        'isAvailable': false,
        'reportedAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
      return null;
    } catch (e) {
      return 'Could not send the report: $e';
    }
  }

  /// A device can send one crowd report per restaurant every 10 minutes.
  Future<String?> reportCrowd(String restaurantId, int level) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'crowd_$restaurantId';
      final last = prefs.getInt(key) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(minutes: 10).inMilliseconds) {
        return 'You already reported this place. Please try again in a few minutes.';
      }
      final device = await deviceId();
      await _db.collection('crowdReports').add({
        'restaurantId': restaurantId,
        'level': level,
        'deviceId': device,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await prefs.setInt(key, now);
      return null;
    } catch (e) {
      return 'Could not send the crowd report: $e';
    }
  }

  // ---------- manager actions ----------
  Future<String?> addItem(MenuItem item) async {
    try {
      await _db
          .collection('restaurants')
          .doc(item.restaurantId)
          .collection('menu')
          .doc(item.id)
          .set(item.toMap());
      return null;
    } catch (e) {
      return 'Could not add the item: $e';
    }
  }

  Future<String?> updateItem(MenuItem item) async {
    try {
      await _itemRef(item).update({
        'name': item.name,
        'description': item.description,
        'price': item.price,
        'imageUrl': item.imageUrl,
      });
      return null;
    } catch (e) {
      return 'Could not update the item: $e';
    }
  }

  Future<String?> deleteItem(MenuItem item) async {
    try {
      await _itemRef(item).delete();
      return null;
    } catch (e) {
      return 'Could not delete the item: $e';
    }
  }

  Future<String?> setAvailable(MenuItem item, bool available) async {
    try {
      await _itemRef(item).update({'isAvailable': available});
      return null;
    } catch (e) {
      return 'Could not change availability: $e';
    }
  }
}

class _RawCrowd {
  final String restaurantId;
  final int level;
  final DateTime createdAt;
  _RawCrowd(this.restaurantId, this.level, this.createdAt);
}

final CampusStore store = CampusStore();

// ============================================================
// SEED DATA – written once when the "restaurants" collection is empty.
// Prices and calories of the new items are sample values.
// ============================================================
class _S {
  final String id, name, desc;
  final double price;
  final int cal;
  final String img;
  final double rating; // starting rating for the original Sprint 1 items
  final int count;
  const _S(
    this.id,
    this.name,
    this.price,
    this.cal,
    this.desc, {
    this.img = '',
    this.rating = 0,
    this.count = 0,
  });
}

Restaurant _r(
  int order,
  String id,
  String name,
  String cat,
  String building,
  double lat,
  double lng,
  String logo,
  String price,
  String walk,
  String hours,
  double pop,
) => Restaurant(
  id: id,
  name: name,
  category: cat,
  logoUrl: logo,
  bannerUrl: logo,
  priceRange: price,
  walkTime: walk,
  hours: hours,
  buildingLocation: building,
  latitude: lat,
  longitude: lng,
  popularity: pop,
  order: order,
);

Future<void> seedIfEmpty() async {
  final db = FirebaseFirestore.instance;
  final existing = await db.collection('restaurants').limit(1).get();
  if (existing.docs.isNotEmpty) return;

  final data = <Restaurant, List<_S>>{
    _r(1, '1', 'dr.CAFE COFFEE', 'Cafes', 'A4 Student Center', 24.8465, 46.7241,
        'assets/logos/dr_cafe.png', r'$$', '3 mins', '7:00 AM - 8:00 PM', 1.0): [
      const _S('m1', 'Iced Creme Brulee Latte', 22, 280,
          'Rich espresso blended with chilled milk, caramel, and vanilla syrup, topped with thick cold foam.',
          img: 'https://images.unsplash.com/photo-1517701604599-bb29b565090c?auto=format&fit=crop&w=400&q=80',
          rating: 4.9, count: 38),
      const _S('m2', 'Mont Blanc Cold Brew', 24, 120,
          'Slow-steeped cold brew coffee offering a crisp taste, topped with orange-infused whipped cream foam.',
          img: 'https://images.unsplash.com/photo-1517701604599-bb29b565090c?auto=format&fit=crop&w=400&q=80',
          rating: 4.6, count: 15),
      const _S('m3', 'Chicken Fajita Panini', 26, 450,
          'Crispy toasted panini sandwich stuffed with grilled chicken strips, bell peppers, fajita spices, and melted cheese.',
          img: 'https://images.unsplash.com/photo-1528735602780-2552fd46c7af?auto=format&fit=crop&w=400&q=80',
          rating: 4.7, count: 29),
      const _S('m12', 'Spanish Latte', 21, 230, 'Espresso with milk and sweetened condensed milk.'),
      const _S('m13', 'Cappuccino', 16, 120, 'Classic espresso with steamed milk and foam.'),
      const _S('m14', 'Pistachio Croissant', 18, 340, 'Buttery croissant filled with pistachio cream.'),
      const _S('m15', 'Caramel Frappe', 23, 360, 'Blended iced coffee with caramel sauce.'),
    ],
    _r(2, '2', 'Window Coffee', 'Cafes', 'A2 Medical and Health', 24.8480, 46.7225,
        'assets/logos/window_coffee.png', r'$$', '5 mins', '7:30 AM - 6:00 PM', 0.8): [
      const _S('m4', 'Window Signature Latte', 23, 210,
          'Signature specialty iced latte combined with fresh milk and a hint of sweetened condensed milk for a smooth taste.',
          img: 'https://images.unsplash.com/photo-1461023058943-07fcbe16d735?auto=format&fit=crop&w=400&q=80',
          rating: 4.8, count: 42),
      const _S('m16', 'Flat White', 17, 130, 'Double espresso with velvety steamed milk.'),
      const _S('m17', 'Iced Spanish Latte', 22, 240, 'Iced latte with condensed milk.'),
      const _S('m18', 'Date Cake', 15, 310, 'Warm date cake with toffee drizzle.'),
      const _S('m19', 'Cheese Croissant', 12, 290, 'Flaky croissant filled with melted cheese.'),
    ],
    _r(3, '3', '12 Cups Roastery', 'Cafes', 'A6 Business', 24.8450, 46.7260,
        'assets/logos/12_cups.png', r'$$$', '7 mins', '7:00 AM - 7:00 PM', 0.9): [
      const _S('m5', 'V60 Ethiopian Guji', 24, 5,
          'Hand-poured specialty filter coffee brewed with premium Ethiopian Guji beans, featuring bright floral and fruity notes.',
          img: 'https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?auto=format&fit=crop&w=400&q=80',
          rating: 4.9, count: 50),
      const _S('m20', 'Espresso', 10, 5, 'Single-origin espresso shot.'),
      const _S('m21', 'Cortado', 15, 90, 'Espresso cut with a little warm milk.'),
      const _S('m22', 'Iced Mocha', 22, 300, 'Espresso, chocolate and milk over ice.'),
      const _S('m23', 'Cardamom Cookie', 9, 210, 'Soft cookie with cardamom and butter.'),
    ],
    _r(4, '4', 'Gong Cha', 'Cafes', 'A4 Food Court', 24.8468, 46.7245,
        'assets/logos/gong_cha.png', r'$$', '4 mins', '8:00 AM - 8:00 PM', 1.0): [
      const _S('m6', 'Black Milk Tea with Boba', 18, 460,
          'Classic fragrant black milk tea served chilled with sweet, chewy tapioca pearls.',
          img: 'https://images.unsplash.com/photo-1558857563-b371033873b8?auto=format&fit=crop&w=400&q=80',
          rating: 4.7, count: 31),
      const _S('m24', 'Matcha Milk Tea', 20, 280, 'Creamy matcha milk tea.'),
      const _S('m25', 'Taro Milk Tea', 19, 320, 'Sweet taro flavoured milk tea.'),
      const _S('m26', 'Lychee Green Tea', 16, 150, 'Light green tea with lychee.'),
      const _S('m27', 'Brown Sugar Milk Tea', 20, 400, 'Milk tea with brown sugar syrup.'),
    ],
    _r(5, '5', 'Dunkin', 'Cafes', 'A1 Administration', 24.8490, 46.7210,
        'assets/logos/dunkin.png', r'$', '2 mins', '6:30 AM - 9:00 PM', 0.8): [
      const _S('m7', 'Boston Kreme Donut', 6, 300,
          'Soft yeast donut filled with rich Bavarian Kreme and topped with a smooth chocolate glaze.',
          img: 'https://images.unsplash.com/photo-1551024709-8f23befc6f87?auto=format&fit=crop&w=400&q=80',
          rating: 4.5, count: 19),
      const _S('m28', 'Glazed Donut', 5, 250, 'Classic ring donut with sugar glaze.'),
      const _S('m29', 'Iced Coffee', 13, 140, 'Cold coffee served over ice.'),
      const _S('m30', 'Hot Latte', 14, 150, 'Espresso with steamed milk.'),
      const _S('m31', 'Chocolate Muffin', 9, 420, 'Soft muffin with chocolate chips.'),
    ],
    _r(6, '6', "Auntie Anne's", 'Restaurants', 'A4 Food Court', 24.8466, 46.7242,
        'assets/logos/auntie_annes.png', r'$$', '6 mins', '8:00 AM - 6:30 PM', 1.1): [
      const _S('m8', 'Original Pretzel Stix', 13, 380,
          'Golden-brown freshly baked pretzel sticks brushed with real butter and lightly sprinkled with salt.',
          img: 'https://images.unsplash.com/photo-1562376552-0d160a2f238d?auto=format&fit=crop&w=400&q=80',
          rating: 4.8, count: 27),
      const _S('m32', 'Cinnamon Sugar Pretzel', 14, 400, 'Warm pretzel with cinnamon sugar.'),
      const _S('m33', 'Cheese Dip', 4, 120, 'Creamy cheese dip.'),
      const _S('m34', 'Pretzel Nuggets', 12, 350, 'Bite-size buttery pretzel pieces.'),
      const _S('m35', 'Lemonade', 10, 180, 'Fresh chilled lemonade.'),
    ],
    _r(7, '7', 'Subway', 'Restaurants', 'A3 Science Building', 24.8475, 46.7230,
        'assets/logos/subway.png', r'$$', '5 mins', '8:00 AM - 8:00 PM', 0.9): [
      const _S('m9', 'Chicken Teriyaki Sub (6-Inch)', 27, 370,
          'Tender chicken strips glazed in sweet teriyaki sauce, layered with crisp fresh vegetables in freshly baked sub bread.',
          img: 'https://images.unsplash.com/photo-1509722747041-616f39b57569?auto=format&fit=crop&w=400&q=80',
          rating: 4.4, count: 18),
      const _S('m36', 'Veggie Delite (6-Inch)', 20, 230, 'Fresh vegetables on freshly baked bread.'),
      const _S('m37', 'Tuna Sub (6-Inch)', 25, 400, 'Tuna with crisp vegetables.'),
      const _S('m38', 'Turkey Breast Sub (6-Inch)', 24, 280, 'Sliced turkey breast with vegetables.'),
      const _S('m39', 'Cookie', 6, 210, 'Freshly baked chocolate chip cookie.'),
    ],
    _r(8, '8', 'Burger Spot', 'Restaurants', 'A4 Food Court', 24.8467, 46.7243,
        'assets/logos/burger_spot.png', r'$$', '4 mins', '10:00 AM - 7:00 PM', 1.0): [
      const _S('m10', 'Classic Cheeseburger', 22, 540,
          'Grilled beef patty with melted American cheese, fresh lettuce, tomato, and house signature sauce on a toasted bun.',
          img: 'https://images.unsplash.com/photo-1568901346375-23c9450c58cd?auto=format&fit=crop&w=400&q=80',
          rating: 4.3, count: 22),
      const _S('m40', 'Double Cheeseburger', 30, 780, 'Two beef patties with double cheese.'),
      const _S('m41', 'Chicken Burger', 24, 520, 'Crispy chicken fillet with lettuce and sauce.'),
      const _S('m42', 'Fries', 9, 365, 'Golden crispy fries.'),
      const _S('m43', 'Milkshake', 16, 450, 'Thick vanilla milkshake.'),
    ],
    _r(9, '9', 'Spar Bakery', 'Restaurants', 'A5 Languages', 24.8460, 46.7250,
        'assets/logos/spar_bakery.png', r'$', '3 mins', '7:00 AM - 8:30 PM', 0.7): [
      const _S('m11', 'Butter Croissant', 8, 260,
          'Freshly baked French-style flaky butter croissant with rich, buttery layers.',
          img: 'https://images.unsplash.com/photo-1555507036-ab1f4038808a?auto=format&fit=crop&w=400&q=80',
          rating: 4.6, count: 14),
      const _S('m44', 'Zaatar Manakish', 7, 300, 'Baked flatbread with zaatar and olive oil.'),
      const _S('m45', 'Cheese Manakish', 8, 350, 'Baked flatbread with melted cheese.'),
      const _S('m46', 'Chicken Sandwich', 14, 380, 'Grilled chicken in a soft roll.'),
      const _S('m47', 'Chocolate Cake Slice', 12, 390, 'Moist chocolate cake slice.'),
    ],
  };

  final batch = db.batch();
  data.forEach((restaurant, menu) {
    final rRef = db.collection('restaurants').doc(restaurant.id);
    batch.set(rRef, restaurant.toMap());
    for (final s in menu) {
      batch.set(rRef.collection('menu').doc(s.id), {
        'restaurantId': restaurant.id,
        'name': s.name,
        'description': s.desc,
        'price': s.price,
        'calories': s.cal,
        'imageUrl': s.img,
        'isAvailable': true,
        'ratingSum': s.rating * s.count,
        'ratingCount': s.count,
      });
    }
  });
  await batch.commit();
}
