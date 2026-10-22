import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AuraFaceProApp());
}

class AuraFaceProApp extends StatelessWidget {
  const AuraFaceProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AuraFace Studio Pro',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF8B5CF6),
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
      ),
      home: const StudioEditorScreen(),
    );
  }
}

enum ProFilter {
  original('Original', Icons.person_outline),
  youngPro('Joven Pro', Icons.face_retouching_natural),
  agingPro('Anciano Pro', Icons.elderly),
  smilePro('Sonrisa Pro', Icons.sentiment_very_satisfied),
  hdRestore('Nitidez HD', Icons.hd_outlined),
  cinemaGlam('Cine Glam', Icons.movie_filter_outlined);

  final String label;
  final IconData icon;
  const ProFilter(this.label, this.icon);
}

class FilterJobPayload {
  final Uint8List sourceBytes;
  final ProFilter filter;
  final double intensity;

  const FilterJobPayload({
    required this.sourceBytes,
    required this.filter,
    required this.intensity,
  });
}

Uint8List executeProFilterIsolate(FilterJobPayload job) {
  if (job.filter == ProFilter.original || job.intensity <= 0.01) {
    return job.sourceBytes;
  }

  final img.Image? baseImage = img.decodeImage(job.sourceBytes);
  if (baseImage == null) return job.sourceBytes;

  img.Image working = baseImage;
  if (baseImage.width > 1280 || baseImage.height > 1280) {
    working = img.copyResize(
      baseImage,
      width: baseImage.width >= baseImage.height ? 1280 : null,
      height: baseImage.height > baseImage.width ? 1280 : null,
    );
  }

  final img.Image originalCopy = img.Image.from(working);
  late img.Image processed;

  switch (job.filter) {
    case ProFilter.original:
      return job.sourceBytes;

    case ProFilter.youngPro:
      final int radius = (3 + (job.intensity * 6)).round();
      final img.Image blurred = img.gaussianBlur( img.Image.from(working), radius: radius);
      processed = img.adjustColor(blurred, brightness: 1.0 + (0.06 * job.intensity), saturation: 1.05);
      break;

    case ProFilter.agingPro:
      final List<num> highPassKernel = [
        -1, -1, -1,
        -1,  9, -1,
        -1, -1, -1,
      ];
      final img.Image sharp = img.convolution(
        img.Image.from(working),
        filter: highPassKernel,
        div: 1.0,
      );
      processed = img.adjustColor(
        sharp,
        contrast: 1.0 + (0.35 * job.intensity),
        saturation: 1.0 - (0.32 * job.intensity),
        gamma: 1.12,
      );
      break;

    case ProFilter.smilePro:
      processed = img.Image.from(working);
      final int w = working.width;
      final int h = working.height;
      final double mouthY = h * 0.64;
      final double leftX = w * 0.36;
      final double rightX = w * 0.64;
      final double radius = w * 0.16;
      final double liftAmount = h * 0.045 * job.intensity;

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          double offsetY = 0.0;
          for (final double cornerX in [leftX, rightX]) {
            final double dx = x - cornerX;
            final double dy = y - mouthY;
            final double distSq = dx * dx + dy * dy;
            if (distSq < radius * radius) {
              final double dist = math.sqrt(distSq);
              final double falloff = math.pow(1.0 - (dist / radius), 2).toDouble();
              offsetY += liftAmount * falloff;
            }
          }
          if (offsetY > 0.1) {
            final int srcY = (y + offsetY).round().clamp(0, h - 1);
            final p = working.getPixel(x, srcY);
            processed.setPixelRgb(x, y, p.r, p.g, p.b);
          }
        }
      }
      break;

    case ProFilter.hdRestore:
      final List<num> hdKernel = [
         0, -1,  0,
        -1,  5, -1,
         0, -1,  0,
      ];
      final img.Image crisp = img.convolution(img.Image.from(working), filter: hdKernel);
      processed = img.adjustColor(crisp, contrast: 1.15, saturation: 1.08);
      break;

    case ProFilter.cinemaGlam:
      processed = img.Image.from(working);
      for (int y = 0; y < processed.height; y++) {
        for (int x = 0; x < processed.width; x++) {
          final p = working.getPixel(x, y);
          final double lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b) / 255.0;
          final int r = (p.r + (lum > 0.5 ? 18 * job.intensity : -6 * job.intensity)).round().clamp(0, 255);
          final int g = (p.g + (lum > 0.5 ? 6 * job.intensity : 4 * job.intensity)).round().clamp(0, 255);
          final int b = (p.b + (lum < 0.5 ? 16 * job.intensity : -10 * job.intensity)).round().clamp(0, 255);
          processed.setPixelRgb(x, y, r, g, b);
        }
      }
      break;
  }

  final img.Image finalImage = img.Image.from(originalCopy);
  final int w = finalImage.width;
  final int h = finalImage.height;
  final double centerX = w / 2.0;
  final double centerY = h / 2.0;
  final double radiusX = w * 0.45;
  final double radiusY = h * 0.48;

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double normX = (x - centerX) / radiusX;
      final double normY = (y - centerY) / radiusY;
      final double ellipseDist = normX * normX + normY * normY;

      double maskWeight = 1.0;
      if (job.filter != ProFilter.cinemaGlam && job.filter != ProFilter.hdRestore) {
        maskWeight = (1.2 - ellipseDist).clamp(0.0, 1.0);
      }

      final double blend = (job.intensity * maskWeight).clamp(0.0, 1.0);
      final pOrig = originalCopy.getPixel(x, y);
      final pProc = processed.getPixel(x, y);

      final int r = (pOrig.r * (1.0 - blend) + pProc.r * blend).round().clamp(0, 255);
      final int g = (pOrig.g * (1.0 - blend) + pProc.g * blend).round().clamp(0, 255);
      final int b = (pOrig.b * (1.0 - blend) + pProc.b * blend).round().clamp(0, 255);
      finalImage.setPixelRgb(x, y, r, g, b);
    }
  }

  return Uint8List.fromList(img.encodeJpg(finalImage, quality: 95));
}

class StudioEditorScreen extends StatefulWidget {
  const StudioEditorScreen({super.key});

  @override
  State<StudioEditorScreen> createState() => _StudioEditorScreenState();
}

class _StudioEditorScreenState extends State<StudioEditorScreen> {
  final ImagePicker _picker = ImagePicker();
  Uint8List? _originalBytes;
  Uint8List? _processedBytes;
  ProFilter _selectedFilter = ProFilter.original;
  double _intensity = 0.80;
  bool _isProcessing = false;
  bool _showOriginalHold = false;

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(source: source, imageQuality: 95);
      if (file == null) return;
      final Uint8List bytes = await file.readAsBytes();
      setState(() {
        _originalBytes = bytes;
        _processedBytes = bytes;
        _selectedFilter = ProFilter.original;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al abrir imagen: $e')));
    }
  }

  Future<void> _applyFilter(ProFilter filter, double intensity) async {
    if (_originalBytes == null) return;
    setState(() {
      _selectedFilter = filter;
      _intensity = intensity;
      _isProcessing = true;
    });

    try {
      final Uint8List result = await compute(
        executeProFilterIsolate,
        FilterJobPayload(
          sourceBytes: _originalBytes!,
          filter: filter,
          intensity: intensity,
        ),
      );
      if (!mounted) return;
      setState(() {
        _processedBytes = result;
        _isProcessing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error procesando filtro: $e')));
    }
  }

  Future<void> _exportAndShare() async {
    if (_processedBytes == null) return;
    final Directory tempDir = await getTemporaryDirectory();
    final String filePath = '${tempDir.path}/AuraFace_Pro_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final File outFile = File(filePath);
    await outFile.writeAsBytes(_processedBytes!);

    await Share.shareXFiles(
      [XFile(outFile.path)],
      text: 'Editado con AuraFace Studio Pro',
    );
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? activeBytes = _showOriginalHold ? _originalBytes : _processedBytes;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        title: Row(
          children: [
            const Icon(Icons.auto_Fix_high, color: Color(0xFFA78BFA)),
            const SizedBox(width: 10),
            const Text('AuraFace ', style: TextStyle(fontWeight: FontWeight.bold)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)]),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('PRO', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
            ),
          ],
        ),
        actions: [
          if (_processedBytes != null) ...[
            GestureDetector(
              onTapDown: (_) => setState(() => _showOriginalHold = true),
              onTapUp: (_) => setState(() => _showOriginalHold = false),
              onTapCancel: () => setState(() => _showOriginalHold = false),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Chip(
                  label: Text(_showOriginalHold ? 'ANTES' : 'COMPARAR'),
                  avatar: const Icon(Icons.compare, size: 18),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Guardar y Compartir',
              icon: const Icon(Icons.ios_share, color: Color(0xFF34D399)),
              onPressed: _exportAndShare,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: activeBytes == null
                  ? _buildEmptyState()
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        InteractiveViewer(
                          minScale: 0.8,
                          maxScale: 4.0,
                          child: Image.memory(activeBytes, fit: BoxFit.contain),
                        ),
                        if (_isProcessing)
                          Container(
                            color: Colors.black54,
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(color: Color(0xFFA78BFA)),
                                  SizedBox(height: 12),
                                  Text('Procesando Red Neuronal...'),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          if (_originalBytes != null) _buildBottomControls(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF8B5CF6).withOpacity(0.15),
            ),
            child: const Icon(Icons.face_retouching_natural, size: 72, color: Color(0xFFA78BFA)),
          ),
          const SizedBox(height: 24),
          const Text(
            'Estudio de Retoque Facial Pro',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Abrir Galería'),
              ),
              OutlinedButton.icon(
                onPressed: () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Tomar Selfie'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_selectedFilter != ProFilter.original)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  const Text('Intensidad', style: TextStyle(fontSize: 13, color: Colors.white70)),
                  Expanded(
                    child: Slider(
                      value: _intensity,
                      min: 0.1,
                      max: 1.0,
                      divisions: 18,
                      label: '${(_intensity * 100).round()}%',
                      onChanged: (val) => setState(() => _intensity = val),
                      onChangeEnd: (val) => _applyFilter(_selectedFilter, val),
                    ),
                  ),
                  Text('${(_intensity * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          SizedBox(
            height: 92,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: ProFilter.values.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _buildToolButton(
                    label: 'Cambiar Foto',
                    icon: Icons.add_photo_alternate_outlined,
                    isSelected: false,
                    onTap: () => _pickImage(ImageSource.gallery),
                  );
                }
                final filter = ProFilter.values[index - 1];
                final isSelected = _selectedFilter == filter;
                return _buildToolButton(
                  label: filter.label,
                  icon: filter.icon,
                  isSelected: isSelected,
                  onTap: () => _applyFilter(filter, _intensity),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolButton({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: _isProcessing ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 88,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF8B5CF6).withOpacity(0.25) : const Color(0xFF1F2937),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFFA78BFA) : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isSelected ? const Color(0xFFA78BFA) : Colors.white70, size: 28),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? Colors.white : Colors.white70,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
