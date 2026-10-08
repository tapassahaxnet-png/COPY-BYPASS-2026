import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/session.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/statistics.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AntiCopyrightApp());
}

class AntiCopyrightApp extends StatelessWidget {
  const AntiCopyrightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anti-Copyright Video Engine',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        brightness: Brightness.light,
        colorSchemeSeed: const Color(0xFF6366F1),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF818CF8),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        cardColor: const Color(0xFF1E293B),
        useMaterial3: true,
      ),
      home: const VideoProcessorScreen(),
    );
  }
}

class VideoProcessorScreen extends StatefulWidget {
  const VideoProcessorScreen({super.key});

  @override
  State<VideoProcessorScreen> createState() => _VideoProcessorScreenState();
}

class _VideoProcessorScreenState extends State<VideoProcessorScreen> {
  final ImagePicker _picker = ImagePicker();
  
  // State variables
  File? _inputVideoFile;
  File? _outputVideoFile;
  VideoPlayerController? _inputPlayerController;
  VideoPlayerController? _outputPlayerController;
  
  bool _isProcessing = false;
  double _progress = 0.0; // 0.0 to 1.0
  int? _totalDurationMs; // Source video duration in milliseconds
  int? _activeSessionId;
  String _statusMessage = 'Select a video from your gallery to get started.';
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  // Core filter definitions from video_processor.py
  static const String ffmpegVideoFilter =
      'crop=trunc(iw*0.96/2)*2:trunc(ih*0.96/2)*2,'
      'eq=contrast=1.04:saturation=1.03:brightness=0.01,'
      'vignette=PI/5,'
      'noise=alls=3:allf=t+u';

  static const String ffmpegAudioFilter =
      'asetrate=44100*1.025,aresample=44100,'
      'atempo=1.015,'
      'equalizer=f=300:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1:g=1,'
      'acompressor=threshold=-12dB:ratio=3:attack=10:release=100';

  @override
  void dispose() {
    _inputPlayerController?.dispose();
    _outputPlayerController?.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  /// Request required media permissions for Android
  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      if (await Permission.videos.isGranted || await Permission.storage.isGranted) {
        return true;
      }
      
      // Android 13+ (API 33+) requires Permission.videos
      final videoStatus = await Permission.videos.request();
      if (videoStatus.isGranted) return true;

      // Android 12 and below requires storage permission
      final storageStatus = await Permission.storage.request();
      if (storageStatus.isGranted) return true;

      return false;
    }
    return true;
  }

  /// Pick video from phone gallery
  Future<void> _pickVideoFromGallery() async {
    try {
      final hasPermission = await _requestPermissions();
      if (!hasPermission) {
        _showSnackBar('Gallery permission is required to select videos.', isError: true);
        return;
      }

      final XFile? pickedFile = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 15),
      );

      if (pickedFile == null) return;

      final file = File(pickedFile.path);
      setState(() {
        _inputVideoFile = file;
        _outputVideoFile = null;
        _progress = 0.0;
        _logs.clear();
        _statusMessage = 'Video loaded: ${file.uri.pathSegments.last}';
      });

      // Initialize preview video controller
      await _initInputPlayer(file);
    } catch (e) {
      _showSnackBar('Failed to pick video: $e', isError: true);
    }
  }

  Future<void> _initInputPlayer(File file) async {
    _inputPlayerController?.dispose();
    _inputPlayerController = VideoPlayerController.file(file);
    await _inputPlayerController!.initialize();
    
    // Store total duration for FFmpeg progress calculation
    _totalDurationMs = _inputPlayerController!.value.duration.inMilliseconds;
    setState(() {});
  }

  Future<void> _initOutputPlayer(File file) async {
    _outputPlayerController?.dispose();
    _outputPlayerController = VideoPlayerController.file(file);
    await _outputPlayerController!.initialize();
    _outputPlayerController!.setLooping(true);
    _outputPlayerController!.play();
    setState(() {});
  }

  /// Execute FFmpeg anti-copyright filter transformation
  Future<void> _bypassCopyright() async {
    if (_inputVideoFile == null) {
      _showSnackBar('Please pick a video first.', isError: true);
      return;
    }

    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _logs.clear();
      _outputVideoFile = null;
      _statusMessage = 'Initializing FFmpeg offline engine...';
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outPath = '${tempDir.path}/bypassed_$timestamp.mp4';

      // Build FFmpeg arguments matching video_processor.py exactly:
      // ffmpeg -y -i <input> -vf <video_filter> -af <audio_filter> 
      // -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart -preset ultrafast <output>
      final String command = 
          '-y -i "${_inputVideoFile!.path}" '
          '-vf "$ffmpegVideoFilter" '
          '-af "$ffmpegAudioFilter" '
          '-c:v libx264 -pix_fmt yuv420p '
          '-c:a aac -b:a 192k '
          '-movflags +faststart '
          '-preset ultrafast '
          '"$outPath"';

      _appendLog('[ENGINE] Executing command:');
      _appendLog('ffmpeg $command');

      // Execute session with real-time log and statistics callbacks
      final session = await FFmpegKit.executeAsync(
        command,
        (FFmpegSession session) async {
          final returnCode = await session.getReturnCode();
          
          if (ReturnCode.isSuccess(returnCode)) {
            _appendLog('[SUCCESS] Anti-copyright processing complete!');
            final resultFile = File(outPath);
            
            setState(() {
              _isProcessing = false;
              _progress = 1.0;
              _outputVideoFile = resultFile;
              _statusMessage = 'Processing finished successfully! Ready to preview or save.';
            });

            await _initOutputPlayer(resultFile);
            _showSnackBar('Video successfully processed!');
          } else if (ReturnCode.isCancel(returnCode)) {
            _appendLog('[CANCELLED] Processing was stopped by user.');
            setState(() {
              _isProcessing = false;
              _statusMessage = 'Operation cancelled.';
            });
          } else {
            _appendLog('[ERROR] FFmpeg failed with state: ${await session.getState()} and return code: $returnCode');
            setState(() {
              _isProcessing = false;
              _statusMessage = 'Encoding failed. Check log console below.';
            });
            _showSnackBar('Processing failed. See execution logs.', isError: true);
          }
        },
        (log) {
          _appendLog(log.getMessage());
        },
        (Statistics statistics) {
          if (_totalDurationMs != null && _totalDurationMs! > 0) {
            final timeInMs = statistics.getTime();
            final calcProgress = (timeInMs / _totalDurationMs!).clamp(0.0, 0.99);
            setState(() {
              _progress = calcProgress;
              _statusMessage = 'Processing: ${(_progress * 100).toStringAsFixed(1)}% '
                  '(fps: ${statistics.getVideoFps().toStringAsFixed(1)}, '
                  'bitrate: ${statistics.getBitrate().toStringAsFixed(0)}kbps)';
            });
          }
        },
      );

      _activeSessionId = session.getSessionId();
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Unexpected error: $e';
      });
      _showSnackBar('Error: $e', isError: true);
    }
  }

  /// Cancel running session
  Future<void> _cancelProcessing() async {
    if (_activeSessionId != null) {
      await FFmpegKit.cancel(_activeSessionId!);
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Cancelling session...';
      });
    }
  }

  /// Save processed output video to Gallery using Gal (Modern Scoped Storage)
  Future<void> _saveToGallery() async {
    if (_outputVideoFile == null || !await _outputVideoFile!.exists()) {
      _showSnackBar('No processed video available to save.', isError: true);
      return;
    }

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final requestGranted = await Gal.requestAccess();
        if (!requestGranted) {
          _showSnackBar('Permission denied. Cannot save to gallery.', isError: true);
          return;
        }
      }

      await Gal.putVideo(_outputVideoFile!.path, album: 'AntiCopyright');
      _showSnackBar('Saved to Gallery album: "AntiCopyright" 🎉');
    } catch (e) {
      _showSnackBar('Failed to save to gallery: $e', isError: true);
    }
  }

  void _appendLog(String text) {
    setState(() {
      _logs.add(text);
    });
    // Auto scroll logs
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnackBar(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.redAccent : Colors.teal,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFF818CF8)),
            SizedBox(width: 8),
            Text(
              'Anti-Copyright Engine',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Filter Parameters',
            onPressed: _showFilterInfoDialog,
          ),
        ],
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF312E81), Color(0xFF1E1B4B)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.step(BorderSide(color: Colors.indigo.shade400.withOpacity(0.3))),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.indigo.shade600.withOpacity(0.4),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.auto_fix_high, color: Colors.amberAccent, size: 28),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Offline Device Processing',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Applies 96% Crop, Dual-band EQ, Vignette & Noise dithering to disrupt automated perceptual hash matchers.',
                            style: TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Button 1: Pick Video from Gallery
              OutlinedButton.icon(
                onPressed: _isProcessing ? null : _pickVideoFromGallery,
                icon: const Icon(Icons.video_library_rounded),
                label: Text(
                  _inputVideoFile == null ? '1. Pick Video from Gallery' : 'Change Video: ${_inputVideoFile!.uri.pathSegments.last}',
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: BorderSide(color: colorScheme.primary),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),

              const SizedBox(height: 16),

              // Video Preview Area (Either Input or Processed Output)
              if (_outputVideoFile != null && _outputPlayerController != null && _outputPlayerController!.value.isInitialized)
                _buildPlayerCard('Processed Video (Bypassed)', _outputPlayerController!, isResult: true)
              else if (_inputVideoFile != null && _inputPlayerController != null && _inputPlayerController!.value.isInitialized)
                _buildPlayerCard('Original Video', _inputPlayerController!, isResult: false),

              const SizedBox(height: 16),

              // Status and Progress indicator
              if (_isProcessing) ...[
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: Colors.grey.shade800,
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
                ),
                const SizedBox(height: 8),
              ],

              Text(
                _statusMessage,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 16),

              // Action Buttons Row
              Row(
                children: [
                  // Button 2: Action button "Bypass Copyright"
                  Expanded(
                    flex: 3,
                    child: ElevatedButton.icon(
                      onPressed: (_inputVideoFile == null || _isProcessing) ? null : _bypassCopyright,
                      icon: _isProcessing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.bolt_rounded),
                      label: Text(
                        _isProcessing ? 'Processing...' : '2. Bypass Copyright',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 4,
                      ),
                    ),
                  ),

                  if (_isProcessing) ...[
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: _cancelProcessing,
                      tooltip: 'Cancel',
                      icon: const Icon(Icons.stop_rounded, color: Colors.redAccent),
                      style: IconButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 12),

              // Button 3: Option to save processed video back to gallery
              ElevatedButton.icon(
                onPressed: (_outputVideoFile == null || _isProcessing) ? null : _saveToGallery,
                icon: const Icon(Icons.download_done_rounded),
                label: const Text(
                  '3. Save Processed Video to Gallery',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade800,
                  disabledForegroundColor: Colors.grey.shade500,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),

              const SizedBox(height: 20),

              // FFmpeg Live Log Terminal
              _buildLogsTerminal(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerCard(String title, VideoPlayerController controller, {required bool isResult}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isResult ? const Color(0xFF10B981).withOpacity(0.5) : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isResult ? Icons.check_circle_rounded : Icons.movie_outlined,
                      color: isResult ? const Color(0xFF10B981) : Colors.grey,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ],
                ),
                IconButton(
                  icon: Icon(
                    controller.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                    color: Colors.indigoAccent,
                  ),
                  onPressed: () {
                    setState(() {
                      controller.value.isPlaying ? controller.pause() : controller.play();
                    });
                  },
                ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio > 0 ? controller.value.aspectRatio : 16 / 9,
              child: VideoPlayer(controller),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsTerminal() {
    return Container(
      height: 180,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF090D16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.terminal, color: Colors.tealAccent, size: 16),
                  SizedBox(width: 6),
                  Text(
                    'FFmpeg Engine Console',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.tealAccent),
                  ),
                ],
              ),
              Text(
                '${_logs.length} lines',
                style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
          const Divider(color: Colors.white12, height: 12),
          Expanded(
            child: _logs.isEmpty
                ? Center(
                    child: Text(
                      'Awaiting job execution...',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey.shade600),
                    ),
                  )
                : ListView.builder(
                    controller: _logScrollController,
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      final line = _logs[index];
                      final isError = line.contains('Error') || line.contains('[ERROR]');
                      final isSuccess = line.contains('[SUCCESS]');
                      return Text(
                        line,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: isError
                              ? Colors.redAccent
                              : isSuccess
                                  ? Colors.greenAccent
                                  : Colors.grey.shade300,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showFilterInfoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.tune, color: Color(0xFF818CF8)),
            SizedBox(width: 8),
            Text('Active Filter Matrix'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Video Filters (-vf):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigoAccent)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(6)),
                child: const Text(
                  ffmpegVideoFilter,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Audio Filters (-af):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigoAccent)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(6)),
                child: const Text(
                  ffmpegAudioFilter,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Encoding & Bitrate:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigoAccent)),
              const SizedBox(height: 4),
              const Text('• Video Codec: libx264 (preset: ultrafast, yuv420p)\n• Audio Codec: aac 192k\n• Container: +faststart for streaming',
                  style: TextStyle(fontSize: 12, color: Colors.white70)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
