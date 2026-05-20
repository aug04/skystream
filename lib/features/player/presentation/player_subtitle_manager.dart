import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../settings/presentation/player_settings_provider.dart';
import './player_controller.dart';

class PlayerSubtitleManager {
  late final PlayerController _controller;

  void initSubtitleManager(PlayerController controller) {
    _controller = controller;
  }

  Future<void> setSubtitleDelay(double seconds) async {
    if (!_controller.currentState.supportsSubtitleDelay) return;

    final native = _controller.player.platform;
    if (native is NativePlayer) {
      await native.setProperty('sub-delay', seconds.toString());
      _controller.updateState((s) => s.copyWith(subtitleDelay: seconds));
    }
  }

    Future<void> applySubtitleSettings(Ref ref) async {
    if (_controller.isDisposed ||
        !_controller.currentState.supportsSubtitleStyling) {
      return;
    }

    final native = _controller.player.platform;
    if (native is NativePlayer) {
      final settings =
          ref.read(playerSettingsProvider).asData?.value ??
          const PlayerSettings();

      // --- BẮT ĐẦU ĐOẠN FIX NETFLIX STYLE ---
      
      // 1. Ép buộc MPV áp dụng cấu hình tùy biến của mình, bỏ qua style gốc thô kệch
      await native.setProperty('sub-ass-override', 'force');

      // 2. Cấu hình cỡ chữ và vị trí dựa theo Settings của người dùng
      await native.setProperty(
        'sub-font-size',
        settings.subtitleSize.toString(),
      );
      await native.setProperty(
        'sub-pos',
        settings.subtitlePosition.round().toString(),
      );

      // Hàm convert màu của tác giả (giữ nguyên)
      String colorToMpvHex(int color, [double opacity = 1.0]) {
        final alpha = (opacity * 255).toInt().toRadixString(16).padLeft(2, '0');
        final rgb = color.toRadixString(16).padLeft(8, '0').substring(2);
        return '#$alpha$rgb';
      }

      // 3. Đặt màu chữ chính (Màu trắng hoặc màu người dùng chọn)
      await native.setProperty(
        'sub-color',
        colorToMpvHex(settings.subtitleColor),
      );

      // 4. THIẾT LẬP HỘP NỀN VÀ PADDING TRÁI PHẢI QUYẾT ĐỊNH
      // BorderStyle=3: Bật chế độ Opaque Box (Hộp nền Netflix)
      // Outline=0: Xóa viền chữ gốc để cái hộp trông mịn màng hơn
      // BackColour: Lấy màu nền + độ mờ từ cài đặt hệ thống (Mặc định thường là Đen mờ)
      final backColorHex = colorToMpvHex(
        settings.subtitleBackgroundColor != 0x00000000 ? settings.subtitleBackgroundColor : 0xFF000000,
        settings.subtitleBackgroundOpacity != 0.0 ? settings.subtitleBackgroundOpacity : 0.65,
      ).replaceAll('#', '&H') + '000000'; // Định dạng ASS yêu cầu mã màu lộn ngược hoặc mã chuẩn của ASS

      // Gửi lệnh gộp Style vào MPV
      await native.setProperty(
        'sub-style',
        'BorderStyle=3,Outline=0,BackColour=$backColorHex',
      );

      // PHÍCH LỖI PADDING TRÁI PHẢI: Ép cái hộp đen phải giãn rộng sang 2 bên chữ 40 đơn vị
      await native.setProperty('sub-margin-x', '40'); 
      // Padding trên dưới và khoảng cách an toàn với đáy
      await native.setProperty('sub-margin-y', '45'); 

      // Cố định font chữ sans-serif cho bo góc text hiển thị mượt mà nhất
      await native.setProperty('sub-font', 'sans-serif');
      
      // --- KẾT THÚC ĐOẠN FIX ---
    }
  }

  List<SubtitleFile> effectiveExternalSubtitles(
    List<SubtitleFile>? streamSubs,
    List<SubtitleFile> userSubs,
  ) {
    final merged = <SubtitleFile>[];
    final seenUrls = <String>{};

    for (final SubtitleFile sub in <SubtitleFile>[...(streamSubs ?? []), ...userSubs]) {
      if (seenUrls.add(sub.url)) {
        merged.add(sub);
      }
    }
    return merged;
  }

  Future<void> loadExternalSubtitleFile({String? filePath}) async {
    if (_controller.currentState.useExoPlayer &&
        !_controller.currentState.supportsExternalSubtitleLoading) {
      return;
    }

    String? path = filePath;
    if (path == null) {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'vtt', 'ass', 'ssa'],
      );
      if (result != null && result.files.single.path != null) {
        path = result.files.single.path!;
      }
    }

    if (path != null) {
      final ext = p.extension(path).toLowerCase().replaceAll('.', '');
      final baseName = p.basenameWithoutExtension(path).trim();
      final label = baseName.isNotEmpty ? baseName : "External ($ext)";
      final newSub = SubtitleFile(url: path, label: label, lang: "und");

      if (!_controller.userAddedExternalSubtitles.any(
        (sub) => sub.url == newSub.url,
      )) {
        _controller.userAddedExternalSubtitles.add(newSub);
        _controller.updateState(
          (s) => s.copyWith(
            externalSubtitles: effectiveExternalSubtitles(
              s.currentStream?.subtitles,
              _controller.userAddedExternalSubtitles,
            ),
          ),
        );
      }

      if (_controller.currentState.useExoPlayer &&
          _controller.currentState.currentStream != null) {
        _controller.pendingVideoViewSubtitleIdsBeforeReload = _controller
            .videoViewController
            ?.mediaInfo
            .value
            ?.subtitleTracks
            .keys
            .toSet();
        _controller.selectNewestVideoViewSubtitleAfterReload =
            !(Platform.isMacOS || Platform.isIOS);

        await _controller.changeStream(
          _controller.currentState.currentStream!,
          resetPosition: false,
        );
        return;
      }

      await _controller.selectSubtitleTrack('external:${newSub.url}');
    }
  }
}
