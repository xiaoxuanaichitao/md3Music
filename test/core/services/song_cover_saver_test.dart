import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/song_cover_saver.dart';
import 'package:md3music/data/models/song.dart';

void main() {
  group('SongCoverSaver.generateCoverFileName', () {
    test('生成包含歌名和歌手的合法文件名', () {
      final song = Song(
        id: '1',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
      );
      final fileName = SongCoverSaver.generateCoverFileName(song);
      expect(fileName, startsWith('MD3Music_晴天_周杰伦_'));
      expect(fileName, endsWith('.jpg'));
    });

    test('过滤文件名中的非法特殊字符', () {
      final song = Song(
        id: '2',
        title: 'Hello/World:Special*Song?name"1<2>3|4',
        artist: 'Singer/Name?*',
        album: 'Album',
      );
      final fileName = SongCoverSaver.generateCoverFileName(song);
      expect(fileName.contains('/'), isFalse);
      expect(fileName.contains(':'), isFalse);
      expect(fileName.contains('*'), isFalse);
      expect(fileName.contains('?'), isFalse);
      expect(fileName.contains('"'), isFalse);
      expect(fileName.contains('<'), isFalse);
      expect(fileName.contains('>'), isFalse);
      expect(fileName.contains('|'), isFalse);
    });

    test('当歌手为空或为未知歌手时只使用歌名', () {
      final song1 = Song(
        id: '3',
        title: '纯音乐',
        artist: '未知歌手',
        album: '',
      );
      final fileName1 = SongCoverSaver.generateCoverFileName(song1);
      expect(fileName1, startsWith('MD3Music_纯音乐_'));

      final song2 = Song(
        id: '4',
        title: '测试歌曲',
        artist: '',
        album: '',
      );
      final fileName2 = SongCoverSaver.generateCoverFileName(song2);
      expect(fileName2, startsWith('MD3Music_测试歌曲_'));
    });
  });
}
