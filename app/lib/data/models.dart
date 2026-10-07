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
  /// 洗澡 / 剪指甲 / 梳毛等日常护理。
  grooming,
  feeding,
  /// 饮水。`valueNum` 存毫升。
  ///
  /// 为什么值得单列：饮水量突然变化是肾脏 / 糖尿病的早期信号，兽医会问
  /// 「最近喝得多吗」—— 而这恰恰是主人记不住的。
  water,
  toilet,
  /// 睡眠。`valueNum` 存小时。突然嗜睡同样是生病信号。
  sleep,
  note;

  String get wireName => switch (this) {
        RecordType.weight => 'weight',
        RecordType.vaccine => 'vaccine',
        RecordType.dewormInternal => 'deworm_internal',
        RecordType.dewormExternal => 'deworm_external',
        RecordType.medication => 'medication',
        RecordType.medical => 'medical',
        RecordType.grooming => 'grooming',
        RecordType.feeding => 'feeding',
        RecordType.water => 'water',
        RecordType.toilet => 'toilet',
        RecordType.sleep => 'sleep',
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
      'grooming' => RecordType.grooming,
      'feeding' => RecordType.feeding,
      'water' => RecordType.water,
      'toilet' => RecordType.toilet,
      'sleep' => RecordType.sleep,
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
    this.personality = const <String>[],
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

  /// 个性特点。存 code（如 `friendly`），显示时再查文案表 —— 换语言不用改数据。
  final List<String> personality;

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
        personality: _strList(m['personality']),
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
        'personality': personality.isEmpty ? null : jsonEncode(personality),
        'archived_at': _ms(archivedAt),
        'tier': tier,
        'created_by': createdBy,
        'created_at': _ms(createdAt)!,
        'updated_at': _ms(updatedAt)!,
        'deleted_at': _ms(deletedAt),
      };

  /// 局部修改。编辑表单只改用户填的字段，id / createdBy / createdAt 一律不动 ——
  /// 手工拼一个新 Pet 太容易漏字段，那是最难查的一类 bug。
  ///
  /// 可空字段用 `clearXxx` 布尔显式置空：`copyWith(note: null)` 的语义是
  /// 「不改 note」还是「把 note 清空」在 Dart 里没法区分，必须分开表达。
  Pet copyWith({
    String? name,
    Species? species,
    String? breed,
    String? gender,
    DateTime? birthday,
    bool? birthdayEstimated,
    DateTime? adoptDate,
    String? avatarUrl,
    double? weightBaseline,
    bool? neutered,
    String? chipNo,
    String? color,
    String? allergy,
    String? note,
    List<String>? personality,
    DateTime? archivedAt,
    String? tier,
    bool clearBreed = false,
    bool clearGender = false,
    bool clearBirthday = false,
    bool clearAdoptDate = false,
    bool clearAvatar = false,
    bool clearWeightBaseline = false,
    bool clearChipNo = false,
    bool clearColor = false,
    bool clearAllergy = false,
    bool clearNote = false,
  }) {
    return Pet(
      id: id,
      name: name ?? this.name,
      species: species ?? this.species,
      breed: clearBreed ? null : (breed ?? this.breed),
      gender: clearGender ? null : (gender ?? this.gender),
      birthday: clearBirthday ? null : (birthday ?? this.birthday),
      birthdayEstimated: birthdayEstimated ?? this.birthdayEstimated,
      adoptDate: clearAdoptDate ? null : (adoptDate ?? this.adoptDate),
      avatarUrl: clearAvatar ? null : (avatarUrl ?? this.avatarUrl),
      weightBaseline: clearWeightBaseline
          ? null
          : (weightBaseline ?? this.weightBaseline),
      neutered: neutered ?? this.neutered,
      chipNo: clearChipNo ? null : (chipNo ?? this.chipNo),
      color: clearColor ? null : (color ?? this.color),
      allergy: clearAllergy ? null : (allergy ?? this.allergy),
      note: clearNote ? null : (note ?? this.note),
      personality: personality ?? this.personality,
      archivedAt: archivedAt ?? this.archivedAt,
      tier: tier ?? this.tier,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      deletedAt: deletedAt,
    );
  }
}

/// JSON 数组字符串 → List<String>。坏数据（不是数组）当空处理，不抛异常 ——
/// 一条脏数据不该让整页打不开。
List<String> _strList(Object? v) {
  if (v == null) return const <String>[];
  final raw = v as String;
  if (raw.trim().isEmpty) return const <String>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.map((e) => '$e').toList(growable: false);
    }
  } on FormatException {
    return const <String>[];
  }
  return const <String>[];
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
  /// 用药疗程见 domain/medication_course.dart，mode 为 medication。
  final Map<String, dynamic> rule;

  final DateTime nextAt;
  final bool enabled;

  /// auto（系统按免疫规程生成）/ manual（用户自建）/ medication_course
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

  /// 周期天数。0 或缺失 = 一次性提醒。
  ///
  /// 界面要显示「每 90 天」这类说明，不能让每个调用点各写一遍取规则的逻辑。
  int get everyDays => (rule['days'] as num?)?.toInt() ?? 0;

  bool get isRecurring => everyDays > 0;

  Reminder copyWith({
    String? type,
    String? title,
    Map<String, dynamic>? rule,
    DateTime? nextAt,
    bool? enabled,
    String? source,
    DateTime? updatedAt,
  }) {
    return Reminder(
      id: id,
      petId: petId,
      type: type ?? this.type,
      title: title ?? this.title,
      rule: rule ?? this.rule,
      nextAt: nextAt ?? this.nextAt,
      enabled: enabled ?? this.enabled,
      source: source ?? this.source,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      deletedAt: deletedAt,
    );
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
    this.updatedAt,
    this.localPath,
    this.remoteUrl,
    this.width,
    this.height,
    this.fileName,
    this.mime,
    this.sizeBytes,
    this.localOnly = false,
    this.deletedAt,
  });

  final String id;
  final String recordId;

  /// 'photo' / 'document'。
  final String kind;

  bool get isDocument => kind == 'document';
  bool get isPhoto => !isDocument;

  /// 应用文档目录内的绝对路径。展示用 Image.file。
  final String? localPath;
  final String? remoteUrl;
  final int? width;
  final int? height;

  /// 文档原件的三个元数据（v6）。照片为 null —— EXIF 与尺寸已经够了，
  /// 而「IMG_20260930.jpg」这种相机名对相册没有意义。
  ///
  /// 存**原始文件名**而不是自己生成一个：用户认的是「狂犬疫苗本.pdf」，
  /// 换成 `doc-<uuid>.pdf` 之后导出/分享给兽医时对方那边也是一串乱码名。
  final String? fileName;

  /// 形如 'application/pdf'。
  final String? mime;

  /// 字节数。列表上显示「2.4 MB」用 —— 用户据此判断这张化验单是不是
  /// 自己要找的那份（扫描件大、照片小）。
  final int? sizeBytes;

  /// true = 只存在本机，不进同步队列（文档原件）。见 schema 的 kSyncSkipWhen。
  final bool localOnly;

  final DateTime createdAt;

  /// 同步的 LWW 基准（v4 补的列）。附件只在「加进来」和「软删」两刻变化，
  /// 创建时它与 createdAt 相等，所以为 null 时按 createdAt 处理。
  final DateTime? updatedAt;

  final DateTime? deletedAt;

  /// 实际用来比新旧的时刻。
  DateTime get effectiveUpdatedAt => updatedAt ?? deletedAt ?? createdAt;

  factory RecordAttachment.fromMap(Map<String, dynamic> m) => RecordAttachment(
        id: m['id'] as String,
        recordId: m['record_id'] as String,
        kind: m['kind'] as String,
        localPath: m['local_path'] as String?,
        remoteUrl: m['remote_url'] as String?,
        width: (m['width'] as num?)?.toInt(),
        height: (m['height'] as num?)?.toInt(),
        fileName: m['file_name'] as String?,
        mime: m['mime'] as String?,
        sizeBytes: (m['size_bytes'] as num?)?.toInt(),
        // 老行这一列是 NULL → false（照片继续同步）。写成 `(m[...] as int) == 1`
        // 会在老库上直接抛，而老库恰恰是升级路径上唯一的真实场景。
        localOnly: ((m['local_only'] as num?)?.toInt() ?? 0) == 1,
        createdAt: _dt(m['created_at'])!,
        updatedAt: _dt(m['updated_at']),
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
        'file_name': fileName,
        'mime': mime,
        'size_bytes': sizeBytes,
        'local_only': localOnly ? 1 : 0,
        'created_at': _ms(createdAt)!,
        // 用 effectiveUpdatedAt 而不是 updatedAt：后者可空，构造时不给就是 null
        // （附件只在「加进来」和「软删」两个时刻变化，创建时两者相等）。
        // 写成 `_ms(updatedAt)!` 会在「new 一个再 toMap」的路径上直接崩，
        // 而且崩在 `!` 上排查起来毫无线索 —— 触发器拿到的 NULL updated_at
        // 还会让这条变更排到所有变更最前面。
        'updated_at': _ms(effectiveUpdatedAt)!,
        'deleted_at': _ms(deletedAt),
      };
}

// ---------------------------------------------------------------- 用户

/// 本地用户。
///
/// 未登录（M6 之前）时只有一行：id = `kCurrentUserId`，region = 'local'。
/// 登录后这一行的 id 换成服务端返回的账号 id，其余字段开始参与同步。
///
/// 为什么联系方式要放在这里而不是塞进「设置」：走失协查卡片要把联系方式
/// 印在卡片上给拾到的人看 —— 它是**宠物档案的一部分**，不是 App 偏好。
class LocalUser {
  const LocalUser({
    required this.id,
    required this.nickname,
    required this.region,
    required this.createdAt,
    required this.updatedAt,
    this.phone,
    this.email,
    this.avatarUrl,
    this.wechat,
    this.contactNote,
  });

  final String id;
  final String nickname;
  final String region;
  final DateTime createdAt;
  final DateTime updatedAt;

  final String? phone;
  final String? email;
  final String? avatarUrl;

  /// 微信号。国内场景下比手机号更常用，所以单列出来。
  final String? wechat;

  /// 其它联系方式，自由文本（如「小区 3 栋 王阿姨」）。
  final String? contactNote;

  /// 有没有任何一条能让人联系上我。走失卡片据此提示用户去补。
  bool get hasContact =>
      [phone, email, wechat, contactNote]
          .any((v) => (v ?? '').trim().isNotEmpty);

  factory LocalUser.fromMap(Map<String, dynamic> m) => LocalUser(
        id: m['id'] as String,
        nickname: (m['nickname'] as String?) ?? '',
        region: (m['region'] as String?) ?? 'local',
        phone: m['phone'] as String?,
        email: m['email'] as String?,
        avatarUrl: m['avatar_url'] as String?,
        wechat: m['wechat'] as String?,
        contactNote: m['contact_note'] as String?,
        createdAt: _dt(m['created_at'])!,
        updatedAt: _dt(m['updated_at'])!,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'nickname': nickname,
        'region': region,
        'phone': phone,
        'email': email,
        'avatar_url': avatarUrl,
        'wechat': wechat,
        'contact_note': contactNote,
        'created_at': _ms(createdAt)!,
        'updated_at': _ms(updatedAt)!,
      };

  LocalUser copyWith({
    String? nickname,
    String? phone,
    String? email,
    String? avatarUrl,
    String? wechat,
    String? contactNote,
    bool clearPhone = false,
    bool clearEmail = false,
    bool clearWechat = false,
    bool clearContactNote = false,
  }) {
    return LocalUser(
      id: id,
      nickname: nickname ?? this.nickname,
      region: region,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      phone: clearPhone ? null : (phone ?? this.phone),
      email: clearEmail ? null : (email ?? this.email),
      avatarUrl: avatarUrl ?? this.avatarUrl,
      wechat: clearWechat ? null : (wechat ?? this.wechat),
      contactNote: clearContactNote ? null : (contactNote ?? this.contactNote),
    );
  }
}

// ---------------------------------------------------------------- 费用

/// 费用类别。存 wire 名不存中文 —— 切语言或改文案时不会变成历史脏数据。
enum ExpenseCategory {
  food, // 主粮 / 零食
  medical, // 就诊 / 用药
  vaccine, // 疫苗
  deworm, // 驱虫
  grooming, // 洗澡美容
  supply, // 用品（玩具、牵引绳、猫砂…）
  boarding, // 寄养 / 托运
  other;

  String get wireName => switch (this) {
        ExpenseCategory.food => 'food',
        ExpenseCategory.medical => 'medical',
        ExpenseCategory.vaccine => 'vaccine',
        ExpenseCategory.deworm => 'deworm',
        ExpenseCategory.grooming => 'grooming',
        ExpenseCategory.supply => 'supply',
        ExpenseCategory.boarding => 'boarding',
        ExpenseCategory.other => 'other',
      };
}

ExpenseCategory expenseCategoryFromWire(String? v) => switch (v) {
      'food' => ExpenseCategory.food,
      'medical' => ExpenseCategory.medical,
      'vaccine' => ExpenseCategory.vaccine,
      'deworm' => ExpenseCategory.deworm,
      'grooming' => ExpenseCategory.grooming,
      'supply' => ExpenseCategory.supply,
      'boarding' => ExpenseCategory.boarding,
      _ => ExpenseCategory.other,
    };

/// 一笔支出。
///
/// 与 [PetRecord] 的区别见 schema 里 createExpenses 的注释：那是「事件」，
/// 这是「钱的流向」。同一天可以有几笔支出而没有任何对应事件。
class Expense {
  const Expense({
    required this.id,
    required this.petId,
    required this.amount,
    required this.currency,
    required this.category,
    required this.spentAt,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.note,
    this.recordId,
    this.deletedAt,
  });

  final String id;
  final String petId;
  final double amount;

  /// ISO 代码（CNY / USD…），不是符号。
  final String currency;

  final ExpenseCategory category;

  /// 消费发生的日期。补录旧账时与 createdAt 不同，必须分开。
  final DateTime spentAt;

  final String? note;

  /// 可选：挂到具体某条记录上（比如「这次疫苗花了 120」）。
  final String? recordId;

  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  factory Expense.fromMap(Map<String, dynamic> m) => Expense(
        id: m['id'] as String,
        petId: m['pet_id'] as String,
        amount: (m['amount'] as num).toDouble(),
        currency: m['currency'] as String,
        category: expenseCategoryFromWire(m['category'] as String?),
        spentAt: _dt(m['spent_at'])!,
        note: m['note'] as String?,
        recordId: m['record_id'] as String?,
        createdBy: m['created_by'] as String,
        createdAt: _dt(m['created_at'])!,
        updatedAt: _dt(m['updated_at'])!,
        deletedAt: _dt(m['deleted_at']),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'pet_id': petId,
        'amount': amount,
        'currency': currency,
        'category': category.wireName,
        'spent_at': _ms(spentAt)!,
        'note': note,
        'record_id': recordId,
        'created_by': createdBy,
        'created_at': _ms(createdAt)!,
        'updated_at': _ms(updatedAt)!,
        'deleted_at': _ms(deletedAt),
      };
}
