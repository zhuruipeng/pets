/// 数据模型。与 schema.dart 的表一一对应。
///
/// 约定：
/// - 时间字段在 Dart 侧是 DateTime，落库转 millisecondsSinceEpoch
/// - 布尔在 SQLite 里是 INTEGER 0/1
/// - payload 是 JSON 字符串，承载各记录类型的特有字段
library;

import 'dart:convert';

import '../../core/species.dart';

// ---------------------------------------------------------------- 转换助手

DateTime? _dt(Object? v) =>
    v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);

int? _ms(DateTime? d) => d?.millisecondsSinceEpoch;

bool _bool(Object? v) => (v as int?) == 1;

int _boolToInt(bool v) => v ? 1 : 0;

Map<String, dynamic> _json(Object? v) {
  if (v == null) return const {};
  if (v is Map<String, dynamic>) return v;
  final raw = v as String;
  if (raw.isEmpty) return const {};
  return jsonDecode(raw) as Map<String, dynamic>;
}

// ---------------------------------------------------------------- 记录类型

enum RecordType {
  weight,
  vaccine,
  dewormInternal,
  dewormExternal,
  medication,
  medical,
  feeding,
  toilet,
  note;

  String get wireName => switch (this) {
        RecordType.weight => 'weight',
        RecordType.vaccine => 'vaccine',
        RecordType.dewormInternal => 'deworm_internal',
        RecordType.dewormExternal => 'deworm_external',
        RecordType.medication => 'medication',
        RecordType.medical => 'medical',
        RecordType.feeding => 'feeding',
        RecordType.toilet => 'toilet',
        RecordType.note => 'note',
      };
}

RecordType recordTypeFromWire(String? v) => switch (v) {
      'weight' => RecordType.weight,
      'vaccine' => RecordType.vaccine,
      'deworm_internal' => RecordType.dewormInternal,
      'deworm_external' => RecordType.dewormExternal,
      'medication' => RecordType.medication,
      'medical' => RecordType.medical,
      'feeding' => RecordType.feeding,
      'toilet' => RecordType.toilet,
      _ => RecordType.note,
    };

// ---------------------------------------------------------------- 宠物

class Pet {
  const Pet({
    required this.id,
    required this.name,
    required this.species,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.breed,
    this.gender,
    this.birthday,
    this.birthdayEstimated = false,
    this.adoptDate,
    this.avatarUrl,
    this.weightBaseline,
    this.neutered = false,
    this.chipNo,
    this.color,
    this.allergy,
    this.note,
    this.archivedAt,
    this.tier = 'free',
    this.deletedAt,
  });

  final String id;
  final String name;
  final Species species;
  final String? breed;
  final String? gender; // male / female / unknown
  final DateTime? birthday;

  /// 生日是「大概」时置 true。老年照护模式依赖这个标记判断可信度。
  final bool birthdayEstimated;

  final DateTime? adoptDate;
  final String? avatarUrl;
  final double? weightBaseline;
  final bool neutered;
  final String? chipNo;
  final String? color;
  final String? allergy;
  final String? note;

  /// 离世后归档，不硬删。数据仍可导出。
  final DateTime? archivedAt;

  /// 商业化档位：'free' | 'premium'。
  ///
  /// V1 不做付费，但这个字段现在就落库 —— 后面接订阅时就不用再动一次
  /// 生产库的 schema。默认 free，UI 目前不读它。
  final String tier;

  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  int? get ageInMonths {
    final b = birthday;
    if (b == null) return null;
    final now = DateTime.now();
    return (now.year - b.year) * 12 + now.month - b.month;
  }

  bool get isSenior {
    final m = ageInMonths;
    return m != null && m >= 84; // 7 岁
  }

  factory Pet.fromMap(Map<String, dynamic> m) => Pet(
        id: m['id'] as String,
        name: m['name'] as String,
        species: speciesFromWire(m['species'] as String?),
        breed: m['breed'] as String?,
        gender: m['gender'] as String?,
        birthday: _dt(m['birthday']),
        birthdayEstimated: _bool(m['birthday_estimated']),
        adoptDate: _dt(m['adopt_date']),
        avatarUrl: m['avatar_url'] as String?,
        weightBaseline: (m['weight_baseline'] as num?)?.toDouble(),
        neutered: _bool(m['neutered']),
        chipNo: m['chip_no'] as String?,
        color: m['color'] as String?,
        allergy: m['allergy'] as String?,
        note: m['note'] as String?,
        archivedAt: _dt(m['archived_at']),
        tier: (m['tier'] as String?) ?? 'free',
        createdBy: m['created_by'] as String,
        createdAt: _dt(m['created_at'])!,
        updatedAt: _dt(m['updated_at'])!,
        deletedAt: _dt(m['deleted_at']),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'species': species.wireName,
        'breed': breed,
        'gender': gender,
        'birthday': _ms(birthday),
        'birthday_estimated': _boolToInt(birthdayEstimated),
        'adopt_date': _ms(adoptDate),
        'avatar_url': avatarUrl,
        'weight_baseline': weightBaseline,
        'neutered': _boolToInt(neutered),
        'chip_no': chipNo,
        'color': color,
        'allergy': allergy,
        'note': note,
        'archived_at': _ms(archivedAt),
        'tier': tier,
        'created_by': createdBy,
        'created_at': _ms(createdAt)!,
        'updated_at': _ms(updatedAt)!,
        'deleted_at': _ms(deletedAt),
      };
}

// ---------------------------------------------------------------- 记录

class PetRecord {
  const PetRecord({
    required this.id,
    required this.petId,
    required this.type,
    required this.recordedAt,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.valueNum,
    this.valueText,
    this.unit,
    this.payload = const {},
    this.note,
    this.deletedAt,
  });

  final String id;
  final String petId;
  final RecordType type;

  /// 事件发生时间。补录历史时与 createdAt 不同，必须分开。
  final DateTime recordedAt;

  final double? valueNum;
  final String? valueText;
  final String? unit;
  final Map<String, dynamic> payload;
  final String? note;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  factory PetRecord.fromMap(Map<String, dynamic> m) => PetRecord(
        id: m['id'] as String,
        petId: m['pet_id'] as String,
        type: recordTypeFromWire(m['type'] as String?),
        recordedAt: _dt(m['recorded_at'])!,
        valueNum: (m['value_num'] as num?)?.toDouble(),
        valueText: m['value_text'] as String?,
        unit: m['unit'] as String?,
        payload: _json(m['payload']),
        note: m['note'] as String?,
        createdBy: m['created_by'] as String,
        createdAt: _dt(m['created_at'])!,
        updatedAt: _dt(m['updated_at'])!,
        deletedAt: _dt(m['deleted_at']),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'pet_id': petId,
        'type': type.wireName,
        'recorded_at': _ms(recordedAt)!,
        'value_num': valueNum,
        'value_text': valueText,
        'unit': unit,
        'payload': payload.isEmpty ? null : jsonEncode(payload),
        'note': note,
        'created_by': createdBy,
        'created_at': _ms(createdAt)!,
        'updated_at': _ms(updatedAt)!,
        'deleted_at': _ms(deletedAt),
      };
}

// ---------------------------------------------------------------- 提醒

class Reminder {
  const Reminder({
    required this.id,
    required this.petId,
    required this.type,
    required this.title,
    required this.rule,
    required this.nextAt,
    required this.createdAt,
    required this.updatedAt,
    this.enabled = true,
    this.source,
    this.deletedAt,
  });

  final String id;
  final String petId;
  final String type;
  final String title;

  /// JSON: {"mode":"interval","days":90} 或 {"mode":"once","at":1730000000000}
  final Map<String, dynamic> rule;

  final DateTime nextAt;
  final bool enabled;

  /// auto（系统按免疫规程生成）/ manual（用户自建）
  final String? source;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  factory Reminder.fromMap(Map<String, dynamic> m) => Reminder(
        id: m['id'] as String,
        petId: m['pet_id'] as String,
        type: m['type'] as String,
        title: m['title'] as String,
        rule: _json(m['rule']),
        nextAt: _dt(m['next_at'])!,
        enabled: _bool(m['enabled']),
        source: m['source'] as String?,
        createdAt: _dt(m['created_at'])!,
        updatedAt: _dt(m['updated_at'])!,
        deletedAt: _dt(m['deleted_at']),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'pet_id': petId,
        'type': type,
        'title': title,
        'rule': jsonEncode(rule),
        'next_at': _ms(nextAt)!,
        'enabled': _boolToInt(enabled),
        'source': source,
        'created_at': _ms(createdAt)!,
        'updated_at': _ms(updatedAt)!,
        'deleted_at': _ms(deletedAt),
      };

  /// 完成后按规则推算下一次触发时间。
  DateTime? nextOccurrence() {
    if (rule['mode'] != 'interval') return null;
    final days = (rule['days'] as num?)?.toInt() ?? 0;
    if (days <= 0) return null;
    return nextAt.add(Duration(days: days));
  }
}

// ---------------------------------------------------------------- 遛狗

class WalkSession {
  const WalkSession({
    required this.id,
    required this.petId,
    required this.startedAt,
    required this.region,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.endedAt,
    this.distanceM = 0,
    this.durationS = 0,
    this.mood,
    this.note,
    this.deletedAt,
  });

  final String id;
  final String petId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double distanceM;
  final int durationS;

  /// 数据分区标记：cn / intl。写库时就带上，便于分区部署与审计。
  final String region;

  /// 这次散步的心情。存 code（great/good/tired/anxious/sick），展示时才翻。
  ///
  /// 为什么本轮就要加：遛狗是所有记录里最高频的一条，一周后的自己
  /// 只看「3.2 公里」回忆不出那天到底怎么样，有了心情才有回放价值。
  final String? mood;

  /// 散步备注。自由文本，比如「遇到了邻居家的大金毛」。
  final String? note;

  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isActive => endedAt == null;

  factory WalkSession.fromMap(Map<String, dynamic> m) => WalkSession(
        id: m['id'] as String,
        petId: m['pet_id'] as String,
        startedAt: _dt(m['started_at'])!,
        endedAt: _dt(m['ended_at']),
        distanceM: (m['distance_m'] as num?)?.toDouble() ?? 0,
        durationS: (m['duration_s'] as num?)?.toInt() ?? 0,
        region: m['region'] as String,
        mood: m['mood'] as String?,
        note: m['note'] as String?,
        createdBy: m['created_by'] as String,
        createdAt: _dt(m['created_at'])!,
        updatedAt: _dt(m['updated_at'])!,
        deletedAt: _dt(m['deleted_at']),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'pet_id': petId,
        'started_at': _ms(startedAt)!,
        'ended_at': _ms(endedAt),
        'distance_m': distanceM,
        'duration_s': durationS,
        'region': region,
        'mood': mood,
        'note': note,
        'created_by': createdBy,
        'created_at': _ms(createdAt)!,
        'updated_at': _ms(updatedAt)!,
        'deleted_at': _ms(deletedAt),
      };
}

class WalkPoint {
  const WalkPoint({
    required this.id,
    required this.sessionId,
    required this.lat,
    required this.lng,
    required this.recordedAt,
    this.altitude,
    this.accuracy,
  });

  final String id;
  final String sessionId;
  final double lat;
  final double lng;
  final double? altitude;

  /// 水平精度（米）。用于过滤漂移点，建议 > 50m 的丢弃。
  final double? accuracy;

  final DateTime recordedAt;

  factory WalkPoint.fromMap(Map<String, dynamic> m) => WalkPoint(
        id: m['id'] as String,
        sessionId: m['session_id'] as String,
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
        altitude: (m['altitude'] as num?)?.toDouble(),
        accuracy: (m['accuracy'] as num?)?.toDouble(),
        recordedAt: _dt(m['recorded_at'])!,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'lat': lat,
        'lng': lng,
        'altitude': altitude,
        'accuracy': accuracy,
        'recorded_at': _ms(recordedAt)!,
      };
}

// ---------------------------------------------------------------- 防丢标签

class PetTag {
  const PetTag({
    required this.id,
    required this.petId,
    required this.tagType,
    required this.createdAt,
    this.tagName,
    this.tagUid,
    this.lastSeenAt,
    this.deletedAt,
  });

  final String id;
  final String petId;

  /// airtag / tile / generic_ble
  final String tagType;

  final String? tagName;
  final String? tagUid;
  final DateTime? lastSeenAt;
  final DateTime createdAt;
  final DateTime? deletedAt;

  factory PetTag.fromMap(Map<String, dynamic> m) => PetTag(
        id: m['id'] as String,
        petId: m['pet_id'] as String,
        tagType: m['tag_type'] as String,
        tagName: m['tag_name'] as String?,
        tagUid: m['tag_uid'] as String?,
        lastSeenAt: _dt(m['last_seen_at']),
        createdAt: _dt(m['created_at'])!,
        deletedAt: _dt(m['deleted_at']),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'pet_id': petId,
        'tag_type': tagType,
        'tag_name': tagName,
        'tag_uid': tagUid,
        'last_seen_at': _ms(lastSeenAt),
        'created_at': _ms(createdAt)!,
        'deleted_at': _ms(deletedAt),
      };
}

// ---------------------------------------------------------------- 附件

/// 记录附件 —— 一条记录的「证据」：药盒照片、处方、X 光片、发票。
///
/// 设计约束（M3.3 定下，改之前先想清楚）：
/// - 永远挂在 record 上，**不给每种记录单开图片字段**；
///   将来加 document / audio 类型，只是 kind 多个取值。
/// - 本地优先：local_path 指向应用文档目录里的拷贝，
///   相册缓存随时可能被系统清掉，不能直接引用相册路径。
/// - remote_url 预留给云同步（M6+），本地版恒为 null。
class RecordAttachment {
  const RecordAttachment({
    required this.id,
    required this.recordId,
    required this.kind,
    required this.createdAt,
    this.localPath,
    this.remoteUrl,
    this.width,
    this.height,
    this.deletedAt,
  });

  final String id;
  final String recordId;

  /// 'photo' / 'document' —— 目前只落 photo，document 等 M6 文件上传。
  final String kind;

  /// 应用文档目录内的绝对路径。展示用 Image.file。
  final String? localPath;
  final String? remoteUrl;
  final int? width;
  final int? height;
  final DateTime createdAt;
  final DateTime? deletedAt;

  factory RecordAttachment.fromMap(Map<String, dynamic> m) => RecordAttachment(
        id: m['id'] as String,
        recordId: m['record_id'] as String,
        kind: m['kind'] as String,
        localPath: m['local_path'] as String?,
        remoteUrl: m['remote_url'] as String?,
        width: (m['width'] as num?)?.toInt(),
        height: (m['height'] as num?)?.toInt(),
        createdAt: _dt(m['created_at'])!,
        deletedAt: _dt(m['deleted_at']),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'record_id': recordId,
        'kind': kind,
        'local_path': localPath,
        'remote_url': remoteUrl,
        'width': width,
        'height': height,
        'created_at': _ms(createdAt)!,
        'deleted_at': _ms(deletedAt),
      };
}
