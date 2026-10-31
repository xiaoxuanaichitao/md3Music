import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/song_download_service.dart';

void main() {
  group('SongDownloadService', () {
    test('sanitizeFileName removes illegal filesystem characters', () {
      expect(
        SongDownloadService.sanitizeFileName('Song/With:Illegal*Chars?'),
        'Song_With_Illegal_Chars_',
      );
      expect(
        SongDownloadService.sanitizeFileName('  Artist <Name> | Title  '),
        'Artist _Name_ _ Title',
      );
    });

    test('formatBytes formats file sizes correctly', () {
      expect(SongDownloadService.formatBytes(0), '0 B');
      expect(SongDownloadService.formatBytes(500), '500 B');
      expect(SongDownloadService.formatBytes(1024), '1.0 KB');
      expect(SongDownloadService.formatBytes(10 * 1024 * 1024), '10.0 MB');
    });
  });
}
