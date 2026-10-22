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
  youngPro('Joven', Icons.face_retouching_natural),
  agingPro('Anciano', Icons.elderly),
  smilePro('Sonrisa', Icons.sentiment_very_satisfied),
  thinFace('Adelgazar', Icons.compress),
  fatFace('Engordar', Icons.expand),
  hdRestore('Nitidez', Icons.hd_outlined),
  cinemaGlam('Cine', Icons.movie_filter_outlined);

  final String label;
  final IconData icon;
  const ProFilter(this.label, this.icon);
}

class FilterJobPayload {
  final Uint8List sourceBytes;
  final ProFilter filter;
  final double intensity;
  final double targetX;
  final double targetY;

  const FilterJobPayload({
    required this.sourceBytes,
    required this.filter,
    required this.intensity,
    required this.targetX,
    required this.targetY,
  });
}

Uint8List executeProFilterIsolate(FilterJobPayload job) {
  if (job.filter == ProFilter.original || job.intensity <= 0.01) {
    return job.sourceBytes;
  }

  final img.Image? baseImage = img.decodeImage(job.sourceBytes);
  if (baseImage == null) return job.sourceBytes;

  img.Image working = baseImage;
  // Optimización: Reducir tamaño para procesamiento rápido en móviles
  if (baseImage.width > 1000 || baseImage.height > 1000) {
    working = img.copyResize(
      baseImage,
      width: baseImage.width >= baseImage.height ? 1000 : null,
      height: baseImage.height > baseImage.width ? 1000 : null,
    );
  }

  final img.Image processed = img.Image.from(working);
  final int w = working.width;
  final int h = working.height;
  
  // Usar el punto tocado por el usuario, o el centro por defecto
  final double tX = job.targetX >= 0 ? job.targetX * w : w / 2.0;
  final double tY = job.targetY >= 0 ? job.targetY * h : h / 2.0;

  switch (job.filter) {
    case ProFilter.youngPro:
      final int radius = (2 + (job.intensity * 4)).round();
      final img.Image blurred = img.gaussianBlur(working, radius: radius);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final pOrig = working.getPixel(x, y);
          final pBlur = blurred.getPixel(x, y);
          // Mezcla de suavizado conservando bordes (simulación básica de filtro bilateral)
          final num luma = pOrig.getLuminance();
          final double blend = job.intensity * (luma > 80 ? 0.8 : 0.2);
          final int r = (pOrig.r * (1.0 - blend) + pBlur.r * blend).round().clamp(0, 255);
          final int g = (pOrig.g * (1.0 - blend) + pBlur.g * blend).round().clamp(0, 255);
          final int b = (pOrig.b * (1.0 - blend) + pBlur.b * blend).round().clamp(0, 255);
          processed.setPixelRgb(x, y, r, g, b);
        }
      }
      img.adjustColor(processed, brightness: 1.0 + (0.1 * job.intensity), saturation: 1.1);
      break;

    case ProFilter.agingPro:
      final List<num> highPassKernel = [
        0, -1, 0,
        -1, 5, -1,
        0, -1, 0,
      ];
      final img.Image sharp = img.convolution(working, filter: highPassKernel, div: 1.0);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final pOrig = working.getPixel(x, y);
          final pSharp = sharp.getPixel(x, y);
          final double blend = job.intensity * 0.7;
          final int r = (pOrig.r * (1.0 - blend) + pSharp.r * blend).round().clamp(0, 255);
          final int g = (pOrig.g * (1.0 - blend) + pSharp.g * blend).round().clamp(0, 255);
          final int b = (pOrig.b * (1.0 - blend) + pSharp.b * blend).round().clamp(0, 255);
          processed.setPixelRgb(x, y, r, g, b);
        }
      }
      img.adjustColor(processed, contrast: 1.0 + (0.2 * job.intensity), saturation: 1.0 - (0.4 * job.intensity));
      break;

    case ProFilter.thinFace: // Pinch (Adelgazar)
    case ProFilter.fatFace:  // Bulge (Engordar)
      final bool isThin = job.filter == ProFilter.thinFace;
      final double radius = math.min(w, h) * (isThin ? 0.4 : 0.35); // Radio de afección
      final double strength = job.intensity * (isThin ? 0.6 : -0.5); // Positivo atrae, Negativo repele

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final double dx = x - tX;
          final double dy = y - tY;
          final double distance = math.sqrt(dx * dx + dy * dy);

          if (distance < radius && distance > 0) {
            double percent = distance / radius;
            // Algoritmo de lente de deformación
            double power = isThin ? (1.0 + strength * (1.0 - percent)) : (1.0 + strength * math.sin(percent * math.pi));
            
            double srcX = tX + dx * math.pow(percent, power) * (radius/distance);
            double srcY = tY + dy * math.pow(percent, power) * (radius/distance);
            
            final p = working.getPixelSafe(srcX.round(), srcY.round());
            processed.setPixelRgb(x, y, p.r, p.g, p.b);
          } else {
            final p = working.getPixel(x, y);
            processed.setPixelRgb(x, y, p.r, p.g, p.b);
          }
        }
      }
      break;

    case ProFilter.smilePro:
      final double radius = math.min(w, h) * 0.25;
      final double lift = radius * 0.3 * job.intensity;
      
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final double dx = x - tX;
          final double dy = y - tY;
          final double distance = math.sqrt(dx * dx + dy * dy);
          
          if (distance < radius) {
            // Curvar hacia arriba (restar a Y) basado en qué tan lejos del centro horizontal esté
            double curve = math.sin((dx.abs() / radius) * math.pi);
            double verticalFalloff = 1.0 - (dy.abs() / radius);
            double offsetY = lift * curve * verticalFalloff;
            
            int srcY = (y + offsetY).round();
            final p = working.getPixelSafe(x, srcY);
            processed.setPixelRgb(x, y, p.r, p.g, p.b);
          } else {
            final p = working.getPixel(x, y);
            processed.setPixelRgb(x, y, p.r, p.g, p.b);
          }
        }
      }
      break;

    case ProFilter.cinemaGlam: // Teal and Orange
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final p = working.getPixel(x, y);
          // Separar luces y sombras
          final num luma = p.getLuminance();
          final double shadow = (255 - luma) / 255.0;
          final double highlight = luma / 255.0;
          
          // Sombras hacia Azul/Cian (Teal), Luces hacia Naranja (Orange)
          int r = (p.r + (highlight * 30 * job.intensity) - (shadow * 10 * job.intensity)).round().clamp(0, 255);
          int g = (p.g + (highlight * 10 * job.intensity) + (shadow * 10 * job.intensity)).round().clamp(0, 255);
          int b = (p.b - (highlight * 20 * job.intensity) + (shadow * 30 * job.intensity)).round().clamp(0, 255);
          
          processed.setPixelRgb(x, y, r, g, b);
        }
      }
      img.adjustColor(processed, contrast: 1.0 + (0.15 * job.intensity));
      break;

    case ProFilter.hdRestore:
      final List<num> hdKernel = [
         -1, -1, -1,
         -1,  9, -1,
         -1, -1, -1,
      ];
      final img.Image crisp = img.convolution(working, filter: hdKernel);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final pOrig = working.getPixel(x, y);
          final pCrisp = crisp.getPixel(x, y);
          final double blend = job.intensity * 0.4;
          final int r = (pOrig.r * (1.0 - blend) + pCrisp.r * blend).round().clamp(0, 255);
          final int g = (pOrig.g * (1.0 - blend) + pCrisp.g * blend).round().clamp(0, 255);
          final int b = (pOrig.b * (1.0 - blend) + pCrisp.b * blend).round().clamp(0, 255);
          processed.setPixelRgb(x, y, r, g, b);
        }
      }
      img.adjustColor(processed, contrast: 1.1, saturation: 1.1);
      break;

    default:
      return job.sourceBytes;
  }

  return Uint8List.fromList(img.encodeJpg(processed, quality: 90));
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
  
  // Coordenadas para apuntar el filtro (0.0 a 1.0)
  double _targetX = -1.0; 
  double _targetY = -1.0;

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(source: source, imageQuality: 90);
      if (file == null) return;
      final Uint8List bytes = await file.readAsBytes();
      setState(() {
        _originalBytes = bytes;
        _processedBytes = bytes;
        _selectedFilter = ProFilter.original;
        _targetX = -1.0; // Reset target
        _targetY = -1.0;
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
          targetX: _targetX,
          targetY: _targetY,
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error procesando: $e')));
    }
  }

  Future<void> _exportAndShare() async {
    if (_processedBytes == null) return;
    final Directory tempDir = await getTemporaryDirectory();
    final String filePath = '${tempDir.path}/AuraFace_Pro_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final File outFile = File(filePath);
    await outFile.writeAsBytes(_processedBytes!);
    await Share.shareXFiles([XFile(outFile.path)], text: 'Editado con AuraFace Studio Pro');
  }

  void _handleImageTap(TapUpDetails details, BoxConstraints constraints) {
    if (_isProcessing) return;
    // Calcular coordenada relativa (0.0 a 1.0)
    setState(() {
      _targetX = details.localPosition.dx / constraints.maxWidth;
      _targetY = details.localPosition.dy / constraints.maxHeight;
    });
    // Reaplicar filtro automáticamente al cambiar el objetivo
    if (_selectedFilter != ProFilter.original) {
      _applyFilter(_selectedFilter, _intensity);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Objetivo fijado. Ahora elige un filtro (Sonrisa, Adelgazar, etc)'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? activeBytes = _showOriginalHold ? _originalBytes : _processedBytes;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        title: Row(
          children: [
            const Icon(Icons.auto_fix_high, color: Color(0xFFA78BFA)),
            const SizedBox(width: 10),
            const Text('AuraFace ', style: TextStyle(fontWeight: FontWeight.bold)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)]),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('PRO V2', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
            ),
          ],
        ),
        actions: [
          if (_processedBytes != null)
            IconButton(
              tooltip: 'Guardar y Compartir',
              icon: const Icon(Icons.ios_share, color: Color(0xFF34D399)),
              onPressed: _exportAndShare,
            ),
        ],
      ),
      body: Column(
        children: [
          // Banner de instrucción
          if (_originalBytes != null)
            Container(
              width: double.infinity,
              color: const Color(0xFF1F2937),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: const Text(
                'Toca el centro del rostro o la boca para fijar el objetivo',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
            
          Expanded(
            child: Center(
              child: activeBytes == null
                  ? _buildEmptyState()
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return GestureDetector(
                              onTapUp: (details) => _handleImageTap(details, constraints),
                              child: Image.memory(activeBytes, fit: BoxFit.contain),
                            );
                          }
                        ),
                        
                        // Mostrar cruz de objetivo
                        if (_targetX >= 0 && _targetY >= 0 && !_showOriginalHold)
                          Positioned(
                            left: MediaQuery.of(context).size.width * _targetX - 12,
                            top: (MediaQuery.of(context).size.height - 300) * _targetY - 12, // Aproximación visual
                            child: const IgnorePointer(
                              child: Icon(Icons.gps_fixed, color: Colors.redAccent, size: 24),
                            ),
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
                                  Text('Calculando deformación...', style: TextStyle(color: Colors.white)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          
          // Botón COMPRAR Reparado (Listener nativo)
          if (_originalBytes != null && _selectedFilter != ProFilter.original)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Listener(
                onPointerDown: (_) => setState(() => _showOriginalHold = true),
                onPointerUp: (_) => setState(() => _showOriginalHold = false),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF374151),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.compare, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text('Mantener para Comparar', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),

          if (_originalBytes != null) _buildBottomControls(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.face_retouching_natural, size: 72, color: Color(0xFFA78BFA)),
        const SizedBox(height: 24),
        Wrap(
          spacing: 16,
          children: [
            FilledButton.icon(
              onPressed: () => _pickImage(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Galería'),
            ),
            OutlinedButton.icon(
              onPressed: () => _pickImage(ImageSource.camera),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Cámara'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
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
                  const Icon(Icons.tune, size: 16, color: Colors.white54),
                  Expanded(
                    child: Slider(
                      value: _intensity,
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      activeColor: const Color(0xFFA78BFA),
                      onChanged: (val) => setState(() => _intensity = val),
                      onChangeEnd: (val) => _applyFilter(_selectedFilter, val),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(
            height: 84,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: ProFilter.values.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final filter = ProFilter.values[index];
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

  Widget _buildToolButton({required String label, required IconData icon, required bool isSelected, required VoidCallback onTap}) {
    return InkWell(
      onTap: _isProcessing ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 76,
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF8B5CF6).withOpacity(0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isSelected ? const Color(0xFFA78BFA) : Colors.transparent),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isSelected ? const Color(0xFFA78BFA) : Colors.white70, size: 26),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(fontSize: 10, color: isSelected ? Colors.white : Colors.white70)),
          ],
        ),
      ),
    );
  }
}
