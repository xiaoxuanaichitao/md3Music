import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/song_match_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/dynamic_cover_view.dart';
import '../../widgets/smart_artwork_image.dart';
import '../utils/app_toast.dart';
import 'dynamic_cover_service.dart';
import 'image_gallery_saver.dart';
import 'local_artwork_cache.dart';

/// 歌曲封面（静态封面 + 动态封面）保存与预览服务。
///
/// 支持在线歌曲（自动尝试最高分辨率 1000px）、动态封面（MP4 视频）、
/// 本地歌曲（从 ID3 标签读取内嵌封面）以及已匹配在线信息的本地歌曲保存至系统相册。
class SongCoverSaver {
  const SongCoverSaver._();

  /// 过滤文件名非法字符并生成友好的封面文件名。
  static String generateCoverFileName(Song song, {String extension = 'jpg'}) {
    final title = song.displayName.trim();
    final artist = song.artist.trim();
    String name;
    if (artist.isNotEmpty && artist != '未知歌手' && !title.contains(artist)) {
      name = '${title}_$artist';
    } else {
      name = title.isNotEmpty ? title : 'cover';
    }
    // 过滤 Windows/Android 文件名中的非法字符
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_').trim();
    if (name.length > 50) {
      name = name.substring(0, 50).trim();
    }
    final salt = (DateTime.now().millisecondsSinceEpoch % 10000)
        .toString()
        .padLeft(4, '0');
    return 'MD3Music_${name}_$salt.$extension';
  }

  /// 解析歌曲对应的 albumAudioId（优先自身字段，其次匹配缓存，最后在线查询详情）。
  static Future<String?> resolveAlbumAudioId(
    BuildContext? context,
    Song song,
  ) async {
    if (song.albumAudioId != null && song.albumAudioId!.trim().isNotEmpty) {
      return song.albumAudioId!.trim();
    }
    if (context != null) {
      try {
        final matchProvider =
            Provider.of<SongMatchProvider>(context, listen: false);
        final matched = matchProvider.matchedSongFor(song);
        if (matched?.albumAudioId != null &&
            matched!.albumAudioId!.trim().isNotEmpty) {
          return matched.albumAudioId!.trim();
        }
      } catch (_) {}
    }
    if (song.isOnline && song.id.trim().isNotEmpty) {
      try {
        final detail = await KugouApiClient().getSongDetail(song.id.trim());
        final resolved = detail?.albumAudioId ?? detail?.albumAudioId2;
        if (resolved != null && resolved.trim().isNotEmpty) {
          return resolved.trim();
        }
      } catch (_) {}
    }
    return null;
  }

  /// 检测歌曲是否存在可保存的动态封面。
  static Future<bool> hasDynamicCover(
    BuildContext? context,
    Song song,
  ) async {
    final albumAudioId = await resolveAlbumAudioId(context, song);
    if (albumAudioId == null || albumAudioId.isEmpty) return false;
    return DynamicCoverService.instance.hasDynamicCover(albumAudioId);
  }

  /// 保存歌曲静态封面并给出 Toast 反馈。
  static Future<bool> saveCoverWithFeedback(
    BuildContext context,
    Song song,
  ) async {
    showToast('正在保存封面…');
    try {
      final success = await saveSongCover(context, song);
      if (success) {
        if (defaultTargetPlatform == TargetPlatform.windows) {
          showToast('封面已保存到相册 (Pictures/MD3Music)');
        } else {
          showToast('封面已保存到系统相册');
        }
        return true;
      } else {
        showToast('该歌曲暂无封面可保存');
        return false;
      }
    } on ImageSaveException catch (e) {
      showToast('保存失败：${e.message}');
      return false;
    } catch (e) {
      debugPrint('[SongCoverSaver] 保存封面失败: $e');
      showToast('保存封面失败');
      return false;
    }
  }

  /// 保存歌曲动态封面（MP4 视频）并给出 Toast 反馈。
  static Future<bool> saveDynamicCoverWithFeedback(
    BuildContext context,
    Song song,
  ) async {
    showToast('正在检测并获取动态封面…');
    try {
      final success = await saveDynamicCover(context, song);
      if (success) {
        if (defaultTargetPlatform == TargetPlatform.windows) {
          showToast('动态封面已保存到相册 (Pictures/MD3Music)');
        } else {
          showToast('动态封面已保存到系统相册 (Movies/MD3Music)');
        }
        return true;
      } else {
        showToast('该歌曲暂无动态封面可保存');
        return false;
      }
    } on ImageSaveException catch (e) {
      showToast('保存动态封面失败：${e.message}');
      return false;
    } catch (e) {
      debugPrint('[SongCoverSaver] 保存动态封面失败: $e');
      showToast('保存动态封面失败');
      return false;
    }
  }

  /// 提取静态封面字节并落盘至相册。
  static Future<bool> saveSongCover(BuildContext context, Song song) async {
    // 1. 本地歌曲：提取本地音频文件内嵌封面
    Uint8List? localBytes;
    if (!song.isOnline) {
      if (song.localPath != null && song.localPath!.isNotEmpty) {
        localBytes = await LocalArtworkCache().getArtwork(song.localPath!);
      }
      if (localBytes == null && song.artworkUri != null) {
        if (song.artworkUri!.startsWith('local://')) {
          final p = song.artworkUri!.replaceFirst('local://', '');
          localBytes = await LocalArtworkCache().getArtwork(p);
        } else if (song.artworkUri!.startsWith('file://')) {
          try {
            final p = Uri.parse(song.artworkUri!).toFilePath();
            localBytes = await LocalArtworkCache().getArtwork(p);
          } catch (_) {}
        }
      }
    }

    if (localBytes != null && localBytes.isNotEmpty) {
      final fileName = generateCoverFileName(song);
      await ImageGallerySaver.saveBytesToGallery(localBytes, fileName: fileName);
      return true;
    }

    // 2. 在线封面地址解析（优先取当前歌曲 artworkUri，若无则尝试在线匹配）
    String? coverUrl;
    if (song.artworkUri != null &&
        (song.artworkUri!.startsWith('http://') ||
            song.artworkUri!.startsWith('https://'))) {
      coverUrl = song.artworkUri;
    } else {
      try {
        final matchProvider =
            Provider.of<SongMatchProvider>(context, listen: false);
        final matched = matchProvider.matchedSongFor(song);
        if (matched?.artworkUri != null &&
            (matched!.artworkUri!.startsWith('http://') ||
                matched.artworkUri!.startsWith('https://'))) {
          coverUrl = matched.artworkUri;
        }
      } catch (_) {}
    }

    if (coverUrl == null || coverUrl.isEmpty) {
      return false;
    }

    // 3. 在线下载封面（自动尝试 1000px 超清尺寸）
    final bytes = await _downloadBestCoverBytes(coverUrl);
    if (bytes == null || bytes.isEmpty) {
      return false;
    }

    final fileName = generateCoverFileName(song);
    await ImageGallerySaver.saveBytesToGallery(bytes, fileName: fileName);
    return true;
  }

  /// 下载并保存歌曲动态封面（MP4 视频）至系统相册。
  static Future<bool> saveDynamicCover(BuildContext context, Song song) async {
    final albumAudioId = await resolveAlbumAudioId(context, song);
    if (albumAudioId == null || albumAudioId.isEmpty) {
      return false;
    }

    final dyCover = await KugouApiClient().getAlbumDyCover(
      albumAudioId,
      albumId: song.albumId,
    );
    if (dyCover == null || !dyCover.hasVideo) {
      return false;
    }

    final candidateUrls = <String>[
      DynamicCoverService.instance.streamUrlFor(albumAudioId),
      if (dyCover.h264Url != null && dyCover.h264Url!.isNotEmpty)
        dyCover.h264Url!,
    ];

    Uint8List? videoBytes;
    for (final url in candidateUrls) {
      try {
        final uri = Uri.parse(url);
        final response =
            await http.get(uri).timeout(const Duration(seconds: 45));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          videoBytes = response.bodyBytes;
          break;
        }
      } catch (e) {
        debugPrint('[SongCoverSaver] 下载动态封面候选地址失败 ($url): $e');
      }
    }

    if (videoBytes == null || videoBytes.isEmpty) {
      throw const ImageSaveException('下载动态封面视频失败');
    }

    final fileName = generateCoverFileName(song, extension: 'mp4');
    await ImageGallerySaver.saveVideoBytesToGallery(
      videoBytes,
      fileName: fileName,
    );
    return true;
  }

  /// 下载最佳分辨率的封面字节。
  static Future<Uint8List?> _downloadBestCoverBytes(String rawUrl) async {
    // 构造候选 URL 列表（超清 1000px 优先，原尺寸兜底）
    final candidateUrls = <String>[];

    if (rawUrl.contains('{size}')) {
      candidateUrls.add(rawUrl.replaceAll('{size}', '1000'));
      candidateUrls.add(rawUrl.replaceAll('{size}', '400'));
    } else if (rawUrl.contains('/400/')) {
      candidateUrls.add(rawUrl.replaceFirst('/400/', '/1000/'));
      candidateUrls.add(rawUrl);
    } else if (rawUrl.contains('/240/')) {
      candidateUrls.add(rawUrl.replaceFirst('/240/', '/1000/'));
      candidateUrls.add(rawUrl);
    } else if (rawUrl.contains('/200/')) {
      candidateUrls.add(rawUrl.replaceFirst('/200/', '/1000/'));
      candidateUrls.add(rawUrl);
    } else if (rawUrl.contains('/150/')) {
      candidateUrls.add(rawUrl.replaceFirst('/150/', '/1000/'));
      candidateUrls.add(rawUrl);
    } else {
      candidateUrls.add(rawUrl);
    }

    // 按优先级尝试请求网络
    for (final url in candidateUrls) {
      try {
        final uri = Uri.parse(url);
        final response =
            await http.get(uri).timeout(const Duration(seconds: 10));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          return response.bodyBytes;
        }
      } catch (_) {
        // 请求失败尝试下一个候选
      }
    }

    // 网络均失败时尝试本地磁盘缓存兜底
    try {
      final cached = await DefaultCacheManager().getFileFromCache(rawUrl);
      if (cached != null && await cached.file.exists()) {
        final bytes = await cached.file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }
    } catch (_) {}

    return null;
  }

  /// 打开歌曲封面预览与保存弹窗。
  static Future<void> showCoverPreviewDialog(
    BuildContext context,
    Song song,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => SongCoverPreviewDialog(song: song),
    );
  }
}

/// 歌曲封面预览与保存弹窗组件。
class SongCoverPreviewDialog extends StatefulWidget {
  final Song song;

  const SongCoverPreviewDialog({super.key, required this.song});

  @override
  State<SongCoverPreviewDialog> createState() => _SongCoverPreviewDialogState();
}

class _SongCoverPreviewDialogState extends State<SongCoverPreviewDialog> {
  bool _savingStatic = false;
  bool _savingDynamic = false;
  bool _hasDynamicCover = false;

  @override
  void initState() {
    super.initState();
    _probeDynamicCover();
  }

  Future<void> _probeDynamicCover() async {
    final hasDy = await SongCoverSaver.hasDynamicCover(null, widget.song);
    if (mounted && hasDy != _hasDynamicCover) {
      setState(() => _hasDynamicCover = hasDy);
    }
  }

  Future<void> _handleSaveStatic() async {
    if (_savingStatic || _savingDynamic) return;
    setState(() => _savingStatic = true);
    try {
      await SongCoverSaver.saveCoverWithFeedback(context, widget.song);
    } finally {
      if (mounted) setState(() => _savingStatic = false);
    }
  }

  Future<void> _handleSaveDynamic() async {
    if (_savingStatic || _savingDynamic) return;
    setState(() => _savingDynamic = true);
    try {
      await SongCoverSaver.saveDynamicCoverWithFeedback(context, widget.song);
    } finally {
      if (mounted) setState(() => _savingDynamic = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final busy = _savingStatic || _savingDynamic;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      backgroundColor: colorScheme.surfaceContainerLow,
      elevation: 6,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '歌曲封面',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 封面图（圆角 + 柔和阴影 + 动态封面叠加预览）
              Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SmartArtworkImage(
                        artworkUri: widget.song.artworkUri,
                        fallbackFilePath: widget.song.localPath,
                        songId: widget.song.id,
                        size: 260,
                        borderRadius: 20,
                      ),
                      if (_hasDynamicCover)
                        DynamicCoverView(
                          song: widget.song,
                          enabled: true,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                widget.song.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                widget.song.artist.isEmpty ? '未知歌手' : widget.song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: busy ? null : _handleSaveStatic,
                  icon: _savingStatic
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_outlined),
                  label: Text(_savingStatic ? '正在保存静态封面…' : '保存静态封面到相册'),
                ),
              ),
              if (_hasDynamicCover) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: busy ? null : _handleSaveDynamic,
                    icon: _savingDynamic
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.motion_photos_on_outlined),
                    label: Text(
                      _savingDynamic ? '正在保存动态封面…' : '保存动态封面到相册 (MP4)',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
