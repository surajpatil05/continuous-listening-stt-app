
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class SpeechService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final MethodChannel _audioChannel =
      const MethodChannel('stt_audio_channel');

  bool _isListening = false;
  bool _isInitialized = false;
  bool _isRestarting = false;
  String _locale = 'en-IN';

  String _committedText = '';
  String _pendingDisplay = '';

  /// Fires on every update — full display string (committed + pending)
  Function(String liveText)? onResult;

  /// Fires only when genuinely new words are committed — sends ONLY new words
  Function(String newWords)? onNewWords;

  Function(bool isListening)? onListeningChanged;
  Function(String error)? onError;

  /// Fires when permissions are permanently denied — caller should open Settings
  Function()? onPermissionPermanentlyDenied;

  bool get isListening => _isListening;

  Future<bool> initialize() async {
    if (Platform.isAndroid) {
      final status = await Permission.microphone.request();
      if (status.isPermanentlyDenied) {
        onPermissionPermanentlyDenied?.call();
        return false;
      }
      if (!status.isGranted) {
        onError?.call('Microphone permission denied');
        return false;
      }
    }
    // iOS: let speech_to_text handle permissions internally.
    // It calls SFSpeechRecognizer.requestAuthorization + AVAudioSession.
    // Using permission_handler before this causes a conflict on iOS.

    _isInitialized = await _speech.initialize(
      onError: (error) {

        if (_isListening) {
          if (Platform.isAndroid) {
            _restartListening();
          } else {
            _isListening = false;
            onListeningChanged?.call(false);
            onError?.call(error.errorMsg);
          }
        }
      },
      onStatus: (status) {
        if (!_isListening) return;

        if (Platform.isAndroid &&
            (status == 'done' || status == 'notListening')) {
          // Android killed the session after silence — restart immediately
          _restartListening();
        } else if (Platform.isIOS && status == 'done') {
          // iOS hit the ~1 minute Apple hard limit — restart once
          _restartListening();
        }
      },
    );

    if (!_isInitialized) {
      onError?.call(
        Platform.isIOS
            ? 'Permission denied. Go to Settings → Privacy → '
              'Microphone and Speech Recognition to enable access.'
            : 'Speech recognition unavailable on this device.',
      );
      onPermissionPermanentlyDenied?.call();
    }

    return _isInitialized;
  }

  Future<void> startListening({required String locale}) async {
    if (!_isInitialized) {
      final success = await initialize();
      if (!success) return;
    }
    _locale = locale;
    _isListening = true;
    _committedText = '';
    _pendingDisplay = '';
    onListeningChanged?.call(true);
    await _startListenSession();
  }

  Future<void> _startListenSession() async {
    // Android: mute system sound BEFORE listen() to suppress the beep
    // that fires during SpeechRecognizer initialization on Android 15.
    // 300ms is the minimum — the audio subsystem needs time to apply
    // the mute before the beep triggers. Tested on Realme P3 / ColorOS.
    if (Platform.isAndroid) {
      await _audioChannel.invokeMethod('muteSystemSound');
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // iOS: small gap ensures AVAudioEngine has fully released resources
    // from any previous session before starting a new one.
    if (Platform.isIOS) {
      await Future.delayed(const Duration(milliseconds: 250));
    }

    try {
      await _speech.listen(
        localeId: _locale,
        onResult: _handleResult,
        // iOS: AVAudioEngine keeps session alive — 5 min is effectively unlimited
        // Android: session will be killed by OS after silence; we restart in onStatus
        listenFor: const Duration(minutes: 5),
        // iOS: AVAudioEngine handles silence natively — large pauseFor works fine
        // Android: pauseFor is largely ignored by the OS; restart loop handles it
        pauseFor: const Duration(seconds: 30),
        partialResults: true,
        cancelOnError: false,
      );
    } catch (e) {
      _isListening = false;
      onListeningChanged?.call(false);
      onError?.call('Failed to start listening: $e');
    }
  }

  void _handleResult(SpeechRecognitionResult result) {
    final newText = result.recognizedWords.trim();

    if (newText.isEmpty) {
      _pendingDisplay = '';
      _notifyLive();
      return;
    }

    if (!result.finalResult) {
      // Partial — strip overlap with committed before displaying
      // Prevents echo tail from showing in live box on Android restarts
      _pendingDisplay = _stripOverlap(_committedText, newText);
      _notifyLive();
    } else {
      // Final — commit with word-level overlap deduplication
      final newWords = _commitWithOverlapCheck(newText);
      _pendingDisplay = '';
      _notifyLive();
      if (newWords.isNotEmpty) {
        onNewWords?.call(newWords);
      }
    }

    // Unmute after beep window passes (Android only)
    if (Platform.isAndroid) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _audioChannel.invokeMethod('unmuteSystemSound');
      });
    }
  }

  String _stripOverlap(String committed, String incoming) {
    if (committed.isEmpty) return incoming;

    final committedWords = committed.trim().split(RegExp(r'\s+'));
    final incomingWords = incoming.trim().split(RegExp(r'\s+'));

    final maxCheck = incomingWords.length < committedWords.length
        ? incomingWords.length
        : committedWords.length;

    for (int len = maxCheck; len >= 1; len--) {
      final committedSuffix = committedWords
          .sublist(committedWords.length - len)
          .join(' ')
          .toLowerCase();
      final incomingPrefix = incomingWords
          .sublist(0, len)
          .join(' ')
          .toLowerCase();

      if (committedSuffix == incomingPrefix) {
        return incomingWords.sublist(len).join(' ');
      }
    }

    return incoming;
  }

  String _commitWithOverlapCheck(String incoming) {
    final seg = incoming.trim();
    if (seg.isEmpty) return '';

    if (_committedText.isEmpty) {
      _committedText = seg;
      return seg;
    }

    final committedWords = _committedText.trim().split(RegExp(r'\s+'));
    final incomingWords = seg.split(RegExp(r'\s+'));

    final maxCheck = incomingWords.length < committedWords.length
        ? incomingWords.length
        : committedWords.length;

    int overlapLength = 0;
    for (int len = maxCheck; len >= 1; len--) {
      final committedSuffix = committedWords
          .sublist(committedWords.length - len)
          .join(' ')
          .toLowerCase();
      final incomingPrefix = incomingWords
          .sublist(0, len)
          .join(' ')
          .toLowerCase();

      if (committedSuffix == incomingPrefix) {
        overlapLength = len;
        break;
      }
    }

    final newWordsList = incomingWords.sublist(overlapLength);
    if (newWordsList.isEmpty) return '';

    final newWordsStr = newWordsList.join(' ');
    _committedText = '${_committedText.trim()} $newWordsStr';
    return newWordsStr;
  }

  void _notifyLive() {
    final display = _pendingDisplay.isEmpty
        ? _committedText
        : _committedText.isEmpty
            ? _pendingDisplay
            : '${_committedText.trim()} ${_pendingDisplay.trim()}';
    onResult?.call(display.trim());
  }

  /// Restart listening — called by Android after every silence timeout,
  /// and by iOS only when the ~1 minute Apple hard limit is hit.
  Future<void> _restartListening() async {
    if (!_isListening) return;
    if (_isRestarting) return;

    _isRestarting = true;
    try {
      if (_pendingDisplay.trim().isNotEmpty) {
        final fullPartial = _committedText.isEmpty
            ? _pendingDisplay
            : '${_committedText.trim()} ${_pendingDisplay.trim()}';
        final newWords = _commitWithOverlapCheck(fullPartial.trim());
        _pendingDisplay = '';
        _notifyLive();
        if (newWords.isNotEmpty) onNewWords?.call(newWords);
      }

      await _speech.stop();
      await Future.delayed(const Duration(milliseconds: 300));

      // Android: mute again before restarting — every speech.listen() call
      // triggers a fresh beep on Android 15
      if (Platform.isAndroid) {
        await _audioChannel.invokeMethod('muteSystemSound');
        await Future.delayed(const Duration(milliseconds: 300));
      }

      // iOS: small gap for AVAudioEngine to release resources
      if (Platform.isIOS) {
        await Future.delayed(const Duration(milliseconds: 250));
      }

      await _speech.listen(
        localeId: _locale,
        onResult: _handleResult,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 30),
        partialResults: true,
        cancelOnError: false,
      );
    } catch (e) {
      _isListening = false;
      onListeningChanged?.call(false);
      onError?.call('Restart failed: $e');
    } finally {
      _isRestarting = false;
    }
  }

  Future<void> stopListening() async {
    _isListening = false;

    if (_pendingDisplay.trim().isNotEmpty) {
      final fullPartial = _committedText.isEmpty
          ? _pendingDisplay
          : '${_committedText.trim()} ${_pendingDisplay.trim()}';
      final newWords = _commitWithOverlapCheck(fullPartial.trim());
      _pendingDisplay = '';
      if (newWords.isNotEmpty) onNewWords?.call(newWords);
    }

    await _speech.stop();

    if (Platform.isAndroid) {
      await _audioChannel.invokeMethod('unmuteSystemSound');
    }

    onListeningChanged?.call(false);
    _notifyLive();
  }

  void dispose() {
    stopListening();
  }
}