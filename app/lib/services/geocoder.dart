/// 逆地理编码抽象 —— 双市场差异点之一。
///
/// 经纬度 → 地址文本。中国走高德，海外走 Mapbox。
/// 之所以只做「地址文本」而不做地图渲染：中国境内地图展示涉及测绘资质，
/// MVP 决定国内版不渲染底图（详见产品结构文档 7.3）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/region.dart';

/// 逆地理编码结果。字段可空，服务商返回能力不同。
class GeoAddress {
  const GeoAddress({
    this.formatted,
    this.country,
    this.city,
    this.district,
  });

  final String? formatted;
  final String? country;
  final String? city;
  final String? district;

  /// 中文场景下优先「城市 + 区」，海外用完整地址。
  String get display => formatted ?? [city, district].whereType<String>().join(' ');

  bool get isEmpty => (formatted ?? '').isEmpty && (city ?? '').isEmpty;
}

/// 所有实现必须遵守的契约。
abstract interface class Geocoder {
  Future<GeoAddress?> reverse({required double lat, required double lng});
}

/// 中国区：高德 Web 服务 API。
///
/// 注意：
/// 1. 需申请高德 Key 并配置到 --dart-define=AMAP_KEY=xxx
/// 2. 必须遵守高德服务条款，不得把返回结果用于地图渲染之外的用途
class AmapGeocoder implements Geocoder {
  AmapGeocoder({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _key = String.fromEnvironment('AMAP_KEY');

  @override
  Future<GeoAddress?> reverse({required double lat, required double lng}) async {
    if (_key.isEmpty) return null;

    final uri = Uri.https('restapi.amap.com', '/v3/geocode/regeo', {
      'key': _key,
      'location': '$lng,$lat',
    });

    try {
      final res = await _client.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['status'] != '1') return null;

      final regeocode = body['regeocode'] as Map<String, dynamic>?;
      final component = regeocode?['addressComponent'] as Map<String, dynamic>?;

      return GeoAddress(
        formatted: regeocode?['formatted_address'] as String?,
        country: component?['country'] as String?,
        city: _asText(component?['city']),
        district: component?['district'] as String?,
      );
    } catch (_) {
      // 逆地理编码失败不能阻塞主流程，轨迹照常记录。
      return null;
    }
  }

  /// 高德在直辖市返回的 city 是空数组，需要兜底到 province。
  static String? _asText(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    if (value is List && value.isNotEmpty) return value.first.toString();
    return null;
  }
}

/// 海外：Mapbox Geocoding API。
class MapboxGeocoder implements Geocoder {
  MapboxGeocoder({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _token = String.fromEnvironment('MAPBOX_TOKEN');

  @override
  Future<GeoAddress?> reverse({required double lat, required double lng}) async {
    if (_token.isEmpty) return null;

    final uri = Uri.https(
      'api.mapbox.com',
      '/geocoding/v5/mapbox.places/$lng,$lat.json',
      {'access_token': _token, 'types': 'place,locality,neighborhood'},
    );

    try {
      final res = await _client.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final features = body['features'] as List<dynamic>?;
      if (features == null || features.isEmpty) return null;

      final first = features.first as Map<String, dynamic>;
      return GeoAddress(formatted: first['place_name'] as String?);
    } catch (_) {
      return null;
    }
  }
}

/// 兜底实现：不请求任何服务，直接返回 null。
///
/// 用于未配置 Key、离线、或用户关闭定位的场景，
/// 保证调用方不需要到处判空。
class NoopGeocoder implements Geocoder {
  const NoopGeocoder();

  @override
  Future<GeoAddress?> reverse({required double lat, required double lng}) async =>
      null;
}

/// 工厂：按区域返回对应实现。业务代码只调用这里。
Geocoder createGeocoder([Region? region]) {
  final r = region ?? AppRegion.current;
  return switch (r) {
    Region.cn => AmapGeocoder(),
    Region.intl => MapboxGeocoder(),
  };
}
