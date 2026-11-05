import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/passenger_id_service.dart';

/// ID type dropdown plus a photo picker with preview, used for passenger
/// identity verification. The parent owns the selected values.
class IdUploadField extends StatelessWidget {
  const IdUploadField({
    super.key,
    required this.idType,
    required this.image,
    required this.onIdTypeChanged,
    required this.onImageChanged,
    this.enabled = true,
    this.errorText,
    this.showTitle = true,
  });

  final String? idType;
  final IdImage? image;
  final ValueChanged<String?> onIdTypeChanged;
  final ValueChanged<IdImage?> onImageChanged;
  final bool enabled;
  final String? errorText;
  final bool showTitle;

  static bool get _canUseCamera =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _pickImage(BuildContext context) async {
    final source = _canUseCamera
        ? await _chooseSource(context)
        : ImageSource.gallery;
    if (source == null) return;
    try {
      final picked = await PassengerIdService.pickImage(source);
      if (picked != null) onImageChanged(picked);
    } on FormatException catch (error) {
      if (context.mounted) _showMessage(context, error.message);
    } on PlatformException catch (error) {
      if (context.mounted) {
        _showMessage(
          context,
          error.code.contains('access_denied')
              ? 'Allow ${source == ImageSource.camera ? 'camera' : 'photo'} '
                    'access in your device settings to upload your ID.'
              : 'Could not open the '
                    '${source == ImageSource.camera ? 'camera' : 'gallery'}: '
                    '${error.message ?? error.code}',
        );
      }
    }
  }

  Future<ImageSource?> _chooseSource(BuildContext context) {
    return showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasError = errorText != null;
    final currentImage = image;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle) ...[
          Text(
            'Identity verification',
            style: TextStyle(
              color: colors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
        ],
        DropdownButtonFormField<String>(
          initialValue: idType,
          isExpanded: true,
          onChanged: enabled ? onIdTypeChanged : null,
          validator: (value) => value == null ? 'Select your ID type' : null,
          decoration: InputDecoration(
            labelText: 'Valid ID type',
            prefixIcon: const Icon(Icons.badge_outlined),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            filled: true,
          ),
          items: [
            for (final entry in PassengerIdService.idTypes.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
        ),
        const SizedBox(height: 12),
        Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? () => _pickImage(context) : null,
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hasError ? colors.error : colors.outlineVariant,
                  width: hasError ? 1.5 : 1,
                ),
              ),
              child: currentImage == null
                  ? _buildEmptyState(colors)
                  : _buildPreview(context, colors, currentImage),
            ),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              errorText!,
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Only TRANSGUARD administrators can see your ID photo. Your full '
          'name must match the ID, because it cannot be changed while the ID '
          'is under review or after it is verified. You can book rides in '
          'the meantime.',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildEmptyState(ColorScheme colors) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.add_a_photo_outlined, size: 36, color: colors.primary),
        const SizedBox(height: 10),
        Text(
          'Upload a photo of your ID',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Front side, all four corners visible, text readable',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context, ColorScheme colors, IdImage img) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(
          img.bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              const Center(child: Text('Preview unavailable')),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: enabled ? () => _pickImage(context) : null,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Replace'),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Remove photo',
                onPressed: enabled ? () => onImageChanged(null) : null,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
