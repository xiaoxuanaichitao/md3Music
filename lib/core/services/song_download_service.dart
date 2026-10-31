import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/song.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_endpoints.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../utils/app_toast.dart';

/// 歌曲音频下载与保存服务
class SongDownloadService {
  const SongDownloadService._();

  static const MethodChannel _channel =
      MethodChannel('com.md3music.md3music/image_saver');

  /// 正在下载中的歌曲 ID 集合，避免重复点击多次下载
  static final Set<String> _downloadingIds = <String>{};

  /// 净化文件名中不合法的操作系统字符
  static String sanitizeFileName(String name) {
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 格式化文件大小展示
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 下载歌曲到本地音乐库
  ///
  /// [song] 需要下载的歌曲
  /// [preferredQuality] 优先音质，默认 [KugouQuality.lossless]（优先 FLAC 无损）
  static Future<void> downloadSong(
    Song song, {
    String? preferredQuality,
  }) async {
    if (!song.isOnline && song.localPath != null && song.localPath!.isNotEmpty) {
      showToast('该歌曲已是本地歌曲，无需下载');
      return;
    }

    if (_downloadingIds.contains(song.id)) {
      showToast('《${song.title}》正在下载中，请勿重复操作');
      return;
    }

    _downloadingIds.add(song.id);

    try {
      showToast('正在获取《${song.title}》下载地址…');

      final targetQuality = preferredQuality ?? KugouQuality.lossless;
      final playUrl = await KugouApiClient().getSongUrlWithFallback(
        song.id,
        quality: targetQuality,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );

      if (playUrl == null || playUrl.url.isEmpty) {
        showToast('获取《${song.title}》下载链接失败，该歌曲可能需要 VIP 或暂无版权');
        return;
      }

      // 根据实际获取到的音质或 URL 决定文件扩展名
      String ext = 'mp3';
      final urlLower = playUrl.url.toLowerCase();
      if (playUrl.quality == KugouQuality.lossless || urlLower.contains('.flac')) {
        ext = 'flac';
      } else if (urlLower.contains('.m4a')) {
        ext = 'm4a';
      }

      final cleanArtist = sanitizeFileName(song.artist);
      final cleanTitle = sanitizeFileName(song.title);
      final stem = cleanArtist.isNotEmpty ? '$cleanArtist - $cleanTitle' : cleanTitle;
      final fileName = '$stem.$ext';

      final qualityName = playUrl.quality.toUpperCase();
      final sizeInfo = playUrl.fileSize > 0 ? ' (${formatBytes(playUrl.fileSize)})' : '';
      showToast('开始下载《${song.title}》[$qualityName]$sizeInfo…');

      // 下载到临时文件
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}${Platform.pathSeparator}dl_${song.id}_$fileName');

      final dio = Dio();
      await dio.download(
        playUrl.url,
        tempFile.path,
        options: Options(
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 5),
        ),
      );

      if (!await tempFile.exists() || (await tempFile.length()) == 0) {
        showToast('下载《${song.title}》失败：写入文件为空');
        return;
      }

      // 保存至目标系统音乐库
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await _channel.invokeMethod<String>('saveAudio', {
            'path': tempFile.path,
            'fileName': fileName,
            'title': song.title,
            'artist': song.artist,
          });
          showToast('《${song.title}》已保存至系统音乐库 (Music/天乐)');
        } catch (e) {
          debugPrint('[SongDownloadService] Android saveAudio error: $e');
          // 降级：保存到应用外置音乐目录
          final extDirs = await getExternalStorageDirectories(type: StorageDirectory.music);
          final baseDir = (extDirs != null && extDirs.isNotEmpty)
              ? extDirs.first
              : await getApplicationDocumentsDirectory();
          final dest = File('${baseDir.path}${Platform.pathSeparator}$fileName');
          await tempFile.copy(dest.path);
          showToast('《${song.title}》已下载至：${dest.path}');
        }
      } else if (defaultTargetPlatform == TargetPlatform.windows) {
        final userProfile = Platform.environment['USERPROFILE'] ?? '';
        final musicDir = Directory('$userProfile\\Music\\天乐');
        if (!await musicDir.exists()) {
          await musicDir.create(recursive: true);
        }
        final dest = File('${musicDir.path}\\$fileName');
        await tempFile.copy(dest.path);
        showToast('《${song.title}》已下载至：Music\\天乐\\$fileName');
      } else {
        final docDir = await getApplicationDocumentsDirectory();
        final dest = File('${docDir.path}${Platform.pathSeparator}$fileName');
        await tempFile.copy(dest.path);
        showToast('《${song.title}》已下载完成');
      }

      // 清理临时文件
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
    } catch (e) {
      debugPrint('[SongDownloadService] download error: $e');
      showToast('下载《${song.title}》失败：$e');
    } finally {
      _downloadingIds.remove(song.id);
    }
  }
}
