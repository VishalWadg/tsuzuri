import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Centralized haptic and acoustic feedback service.
///
/// Directs vibrations to the Android hardware [Vibrator] via platform channel,
/// ensuring vibrations fire even if the device has global "touch feedback" disabled.
class FeedbackService {
  static const MethodChannel _channel = MethodChannel('com.tsuzuri.kanji/feedback');

  /// Trigger feedback for a correct stroke: 1 vibration + subtle click sound.
  static Future<void> notifySuccess({required bool hapticsEnabled}) async {
    unawaited(SystemSound.play(SystemSoundType.click));

    if (!hapticsEnabled) return;

    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _channel.invokeMethod('vibrateSuccess');
      } else {
        await HapticFeedback.lightImpact();
      }
    } catch (_) {
      await HapticFeedback.lightImpact();
    }
  }

  /// Trigger feedback for an incorrect stroke: 2 vibrations + subtle alert sound.
  static Future<void> notifyFailure({required bool hapticsEnabled}) async {
    unawaited(SystemSound.play(SystemSoundType.alert));

    if (!hapticsEnabled) return;

    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _channel.invokeMethod('vibrateFailure');
      } else {
        // Fallback for non-Android platforms: two pulses spaced by 90ms
        await HapticFeedback.mediumImpact();
        await Future<void>.delayed(const Duration(milliseconds: 90));
        await HapticFeedback.mediumImpact();
      }
    } catch (_) {
      await HapticFeedback.mediumImpact();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      await HapticFeedback.mediumImpact();
    }
  }

  /// Trigger celebration feedback on completing all strokes of a kanji.
  static Future<void> notifyCharacterCompleted({required bool hapticsEnabled}) async {
    unawaited(SystemSound.play(SystemSoundType.click));

    if (!hapticsEnabled) return;

    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _channel.invokeMethod('vibrateComplete');
      } else {
        await HapticFeedback.heavyImpact();
      }
    } catch (_) {
      await HapticFeedback.heavyImpact();
    }
  }
}
