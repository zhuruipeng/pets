/// 头像文件的落地与清理。
///
/// 与附件同一套约定：**先把图拷进应用文档目录，再把新路径写进库**。
/// 直接存相册/相机给的路径是行不通的 —— 那多半在缓存目录，系统清一次
/// 头像就变成一块灰。附件那边为此写了很长的注释，这里是同一条理由。
///
/// 与附件唯一的差别在删除策略：
/// - 附件是「一条记录多张图」，删一张不能删文件（可能是共享/待恢复的）；
/// - 头像是「一只宠物一张图」，换新图时旧图不会被任何地方引用，留着只是垃圾。
///   所以这里换头像会顺手删掉旧文件。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AvatarStore {
  AvatarStore._();

  static const String _folder = 'avatars';

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, _folder));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 把选中的图片收编：拷贝进应用目录，返回新路径。
  ///
  /// 文件名带毫秒时间戳 —— 同一次编辑里连换两张不会互相覆盖，
  /// 出问题时也能一眼看出是哪次换的。拷贝失败直接抛，让调用方报错：
  /// 宁可提示「保存失败」，也不要留一条指向临时文件的死路径。
  static Future<String> import(String sourcePath, {required String petId}) async {
    final src = File(sourcePath);
    if (!src.existsSync()) {
      throw StateError('头像源文件不存在: $sourcePath');
    }
    final ext = p.extension(sourcePath).isEmpty
        ? '.jpg'
        : p.extension(sourcePath).toLowerCase();
    final name = '${petId}_${DateTime.now().millisecondsSinceEpoch}$ext';
    final dest = p.join((await _dir()).path, name);
    await src.copy(dest);
    return dest;
  }

  /// 删旧头像。**失败不抛** —— 删文件失败不该挡住「换头像」这件事本身，
  /// 最坏结果只是应用目录里多留一个几十 KB 的孤儿文件。
  static Future<void> deleteQuietly(String? path) async {
    final target = (path ?? '').trim();
    if (target.isEmpty) return;
    // 只删自己目录里的东西：avatarUrl 有可能被同步功能写成远端 URL，
    // 那种值不该拿去 File 删。
    if (!p.basename(target).contains('.') || target.startsWith('http')) return;
    try {
      final f = File(target);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // 忽略
    }
  }
}
