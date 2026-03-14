import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'speech_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Continuous Listening STT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const NoteScreen(),
    );
  }
}

class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key});

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen>
    with SingleTickerProviderStateMixin {
  final SpeechService _speechService = SpeechService();
  final TextEditingController _editorController = TextEditingController();
  late AnimationController _pulseController;

  bool _isListening = false;
  String _liveTranscript = '';
  String _selectedLanguage = 'en-IN';

  // All languages supported by Google STT on Android.
  // Text is returned in the native script of the language:
  // Hindi → Devanagari, Telugu → Telugu script, Tamil → Tamil script, etc.
  static const Map<String, String> _androidLanguages = {
    'English': 'en-IN',
    'Hindi': 'hi-IN',
    'Telugu': 'te-IN',
    'Tamil': 'ta-IN',
    'Kannada': 'kn-IN',
    'Malayalam': 'ml-IN',
    'Marathi': 'mr-IN',
    'Gujarati': 'gu-IN',
    'Bengali': 'bn-IN',
    'Punjabi': 'pa-IN',
    'Urdu': 'ur-IN',
    'Odia': 'or-IN',
    'Assamese': 'as-IN',
  };

  // iOS SFSpeechRecognizer reliably supports English and Hindi only.
  // Other Indian languages are not available on iOS.
  static const Map<String, String> _iosLanguages = {
    'English': 'en-IN',
    'Hindi': 'hi-IN',
  };

  // Returns the correct language map for the current platform
  Map<String, String> get _availableLanguages =>
      Platform.isIOS ? _iosLanguages : _androidLanguages;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // Drives the live transcription box only
    _speechService.onResult = (liveText) {
      if (mounted) setState(() => _liveTranscript = liveText);
    };

    _speechService.onListeningChanged = (val) {
      if (mounted) {
        setState(() => _isListening = val);
        if (val) {
          _pulseController.repeat(reverse: true);
        } else {
          _pulseController.stop();
          _pulseController.reset();
        }
      }
    };

    _speechService.onError = (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $err'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    };

    // Fires when permissions are permanently denied (iOS or Android).
    // Shows a dialog to send the user to app Settings.
    _speechService.onPermissionPermanentlyDenied = () {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Permission Required'),
          content: Text(
            Platform.isIOS
                ? 'Microphone and Speech Recognition access is required.\n\n'
                  'Please go to Settings → Privacy & Security → Microphone '
                  'and Speech Recognition and enable access for this app.'
                : 'Microphone access is required.\n\n'
                  'Please go to Settings → Apps → Continuous Listening STT '
                  '→ Permissions and enable Microphone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    };
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speechService.stopListening();
    } else {
      // Reset selected language to English if switching from a language
      // that's not available on iOS
      if (Platform.isIOS && !_iosLanguages.containsValue(_selectedLanguage)) {
        setState(() => _selectedLanguage = 'en-IN');
      }
      setState(() => _liveTranscript = '');
      await _speechService.startListening(locale: _selectedLanguage);
    }
  }

  void _insertIntoEditor() {
    if (_liveTranscript.isEmpty) return;
    final current = _editorController.text.trim();
    _editorController.text =
        current.isEmpty ? _liveTranscript : '$current $_liveTranscript';
    _editorController.selection = TextSelection.fromPosition(
      TextPosition(offset: _editorController.text.length),
    );
  }

  void _clearAll() {
    setState(() => _liveTranscript = '');
    _editorController.clear();
  }

  void _copyToClipboard() {
    final text = _editorController.text;
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  @override
  void dispose() {
    _speechService.dispose();
    _pulseController.dispose();
    _editorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Continuous Listening STT'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy note',
            onPressed: _copyToClipboard,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear all',
            onPressed: _clearAll,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Language selector — shows all languages on Android, English + Hindi on iOS
            DropdownButtonFormField<String>(
              initialValue: _selectedLanguage,
              decoration: InputDecoration(
                labelText: Platform.isIOS
                    ? 'Speak Language (English & Hindi on iOS)'
                    : 'Speak Language',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: _availableLanguages.entries.map((entry) {
                return DropdownMenuItem(
                  value: entry.value,
                  child: Text(entry.key),
                );
              }).toList(),
              onChanged: _isListening
                  ? null
                  : (val) => setState(() => _selectedLanguage = val!),
            ),

            const SizedBox(height: 14),

            // Listening indicator
            if (_isListening)
              FadeTransition(
                opacity: _pulseController,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.fiber_manual_record,
                          color: Colors.red, size: 12),
                      SizedBox(width: 6),
                      Text('Listening...',
                          style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 14),

            // Live transcription box
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 80),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Live Transcription',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _liveTranscript.isEmpty
                        ? 'Tap the mic and start speaking...'
                        : _liveTranscript,
                    style: TextStyle(
                      fontSize: 15,
                      color: _liveTranscript.isEmpty
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // Insert / Clear buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _liveTranscript.isEmpty ? null : _insertIntoEditor,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Insert into Note'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _liveTranscript = ''),
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('Clear'),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // Note editor label
            Text(
              'Note',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),

            const SizedBox(height: 6),

            // Note editor — filled manually via Insert button
            Expanded(
              child: TextField(
                controller: _editorController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: 'Your note will appear here...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  filled: true,
                ),
              ),
            ),
          ],
        ),
      ),

      // Pulsing mic FAB
      floatingActionButton: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return Transform.scale(
            scale: _isListening
                ? 1.0 + (_pulseController.value * 0.15)
                : 1.0,
            child: FloatingActionButton.large(
              onPressed: _toggleListening,
              backgroundColor: _isListening
                  ? Colors.red
                  : Theme.of(context).colorScheme.primary,
              child: Icon(
                _isListening ? Icons.stop : Icons.mic,
                size: 36,
                color: Colors.white,
              ),
            ),
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}