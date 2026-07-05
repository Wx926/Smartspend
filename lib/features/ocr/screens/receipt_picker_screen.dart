import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/models/recent_receipt_model.dart';
import '../../../shared/services/local_storage_service.dart';

/// Custom receipt picker matching the FYP mockup — replaces the OS system
/// photo picker (which can't be themed) with an in-app green-branded grid.
/// "Recents" is SmartSpend's own recently-picked files (images + PDFs, real
/// thumbnails, stored locally); "Camera Roll" is the real device photo
/// gallery via photo_manager. Returns the picked file path via Navigator.pop.
class ReceiptPickerScreen extends StatefulWidget {
  const ReceiptPickerScreen({super.key});

  @override
  State<ReceiptPickerScreen> createState() => _ReceiptPickerScreenState();
}

class _ReceiptPickerScreenState extends State<ReceiptPickerScreen> {
  static const _uuid = Uuid();

  List<RecentReceiptModel> _recents = [];
  List<AssetEntity> _cameraRoll = [];
  bool _loadingGallery = true;
  bool _galleryPermissionDenied = false;
  bool _addingPdf = false;

  String? _selectedPath;
  bool _selectedIsAsset = false; // true if selection came from Camera Roll
  String? _selectedAssetId; // tracked separately since asset.file is async

  @override
  void initState() {
    super.initState();
    _recents = LocalStorageService.instance.getRecentReceipts();
    _loadCameraRoll();
  }

  Future<void> _loadCameraRoll() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      setState(() {
        _galleryPermissionDenied = true;
        _loadingGallery = false;
      });
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (albums.isEmpty) {
      setState(() => _loadingGallery = false);
      return;
    }
    final assets = await albums.first.getAssetListRange(start: 0, end: 30);
    if (!mounted) return;
    setState(() {
      _cameraRoll = assets;
      _loadingGallery = false;
    });
  }

  Future<void> _addPdf() async {
    setState(() => _addingPdf = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      final path = result?.files.single.path;
      if (path == null) return;

      final thumbPath = await _renderPdfThumbnail(path);
      final receipt = RecentReceiptModel(
        id: _uuid.v4(),
        filePath: path,
        thumbnailPath: thumbPath,
        isPdf: true,
        addedAt: DateTime.now(),
      );
      await LocalStorageService.instance.addRecentReceipt(receipt);
      if (!mounted) return;
      setState(() {
        _recents = LocalStorageService.instance.getRecentReceipts();
        _selectedPath = path;
        _selectedIsAsset = false;
        _selectedAssetId = null;
      });
    } finally {
      if (mounted) setState(() => _addingPdf = false);
    }
  }

  Future<String> _renderPdfThumbnail(String pdfPath) async {
    final doc = await PdfDocument.openFile(pdfPath);
    final page = await doc.getPage(1);
    final image = await page.render(
      width: page.width * 0.6,
      height: page.height * 0.6,
      format: PdfPageImageFormat.png,
    );
    await page.close();
    await doc.close();

    final dir = await getApplicationDocumentsDirectory();
    final thumbFile = File(
        '${dir.path}/receipt_thumb_${DateTime.now().millisecondsSinceEpoch}.png');
    await thumbFile.writeAsBytes(image!.bytes);
    return thumbFile.path;
  }

  Future<void> _selectAsset(AssetEntity asset) async {
    // Set the id synchronously so the checkmark appears immediately, instead
    // of waiting on the async file resolution below.
    setState(() {
      _selectedAssetId = asset.id;
      _selectedIsAsset = true;
      _selectedPath = null;
    });
    final file = await asset.file;
    if (file == null || !mounted) return;
    setState(() {
      _selectedPath = file.path;
    });
  }

  Future<void> _useSelected() async {
    if (_selectedPath == null) return;

    // Remember gallery picks in Recents too (not just PDFs) so they show up
    // as real thumbnails next time, same as a freshly-added PDF would.
    if (_selectedIsAsset) {
      await LocalStorageService.instance.addRecentReceipt(RecentReceiptModel(
        id: _uuid.v4(),
        filePath: _selectedPath!,
        thumbnailPath: _selectedPath!,
        isPdf: false,
        addedAt: DateTime.now(),
      ));
    }

    if (!mounted) return;
    Navigator.pop(context, _selectedPath);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        foregroundColor: AppColors.textWhite,
        title: const Text('Choose Receipt'),
        actions: [
          TextButton(
            onPressed: _selectedPath == null ? null : _useSelected,
            child: Text(
              'Use Selected',
              style: TextStyle(
                color: _selectedPath == null
                    ? AppColors.textWhite.withValues(alpha: 0.4)
                    : AppColors.textWhite,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionLabel('RECENTS'),
                const SizedBox(height: 10),
                _buildRecentsGrid(),
                const SizedBox(height: 24),
                _sectionLabel('CAMERA ROLL'),
                const SizedBox(height: 10),
                _buildCameraRollGrid(),
                const SizedBox(height: 16),
              ],
            ),
          ),
          _buildUseSelectedButton(),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
          letterSpacing: 0.5,
        ),
      );

  Widget _buildRecentsGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _recents.length + 1,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1,
      ),
      itemBuilder: (context, index) {
        if (index == 0) return _buildAddPdfTile();
        final receipt = _recents[index - 1];
        final selected = _selectedPath == receipt.filePath;
        return _Tile(
          selected: selected,
          badge: receipt.isPdf ? 'PDF' : null,
          onTap: () => setState(() {
            _selectedPath = receipt.filePath;
            _selectedIsAsset = false;
            _selectedAssetId = null;
          }),
          child: Image.file(File(receipt.thumbnailPath), fit: BoxFit.cover),
        );
      },
    );
  }

  Widget _buildAddPdfTile() {
    return _Tile(
      selected: false,
      dashed: true,
      onTap: _addingPdf ? null : _addPdf,
      child: _addingPdf
          ? const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.picture_as_pdf_outlined,
                      color: AppColors.primary, size: 26),
                  SizedBox(height: 4),
                  Text('Add PDF',
                      style:
                          TextStyle(fontSize: 11, color: AppColors.primary)),
                ],
              ),
            ),
    );
  }

  Widget _buildCameraRollGrid() {
    if (_loadingGallery) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_galleryPermissionDenied) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            const Text(
              'Photo access denied. Enable it in Settings to browse your gallery.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            TextButton(
              onPressed: PhotoManager.openSetting,
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    }
    if (_cameraRoll.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text('No photos found',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _cameraRoll.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1,
      ),
      itemBuilder: (context, index) {
        final asset = _cameraRoll[index];
        return FutureBuilder<Uint8List?>(
          future: asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            return _Tile(
              selected: _selectedAssetId == asset.id,
              onTap: () => _selectAsset(asset),
              child: bytes != null
                  ? Image.memory(bytes, fit: BoxFit.cover)
                  : Container(color: AppColors.primarySurface),
            );
          },
        );
      },
    );
  }

  Widget _buildUseSelectedButton() {
    final enabled = _selectedPath != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: enabled ? _useSelected : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryDark,
              disabledBackgroundColor:
                  AppColors.primaryDark.withValues(alpha: 0.4),
              foregroundColor: AppColors.textWhite,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
            ),
            child: const Text('Use Selected Photo',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final Widget child;
  final bool selected;
  final bool dashed;
  final String? badge;
  final VoidCallback? onTap;

  const _Tile({
    required this.child,
    required this.selected,
    this.dashed = false,
    this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(14),
              border: dashed
                  ? Border.all(
                      color: AppColors.primary.withValues(alpha: 0.4),
                      width: 1.4,
                    )
                  : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
          if (selected)
            Container(
              decoration: BoxDecoration(
                color: AppColors.primaryDark.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Center(
                child: Icon(Icons.check_circle,
                    color: AppColors.textWhite, size: 30),
              ),
            ),
          if (badge != null && !selected)
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primaryDark,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(badge!,
                    style: const TextStyle(
                        color: AppColors.textWhite,
                        fontSize: 9,
                        fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      ),
    );
  }
}
