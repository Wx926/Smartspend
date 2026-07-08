import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/models/budget_model.dart';
import '../../../shared/models/expense_model.dart';
import '../../../shared/services/supabase_service.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/budget/providers/budget_provider.dart';
import '../../../features/expenses/providers/expense_provider.dart';
import '../models/ocr_result.dart';
import 'receipt_success_screen.dart';

class ReceiptReviewScreen extends StatefulWidget {
  /// Fresh-scan mode: the OCR or voice-parsed result just returned by the
  /// backend.
  final OcrResult? result;
  final XFile? imageFile;
  /// Expense source recorded on save for fresh-scan mode — 'ocr' for a
  /// scanned receipt, 'voice' for a voice-entered expense. Ignored in edit
  /// mode, which keeps each row's original source.
  final String source;

  /// Edit mode: every ExpenseModel row already saved under the same batchId
  /// (or the row's own id, for single-item receipts saved without one) —
  /// passed in from Receipt History when the user taps a saved receipt.
  final List<ExpenseModel>? existingExpenses;

  const ReceiptReviewScreen({
    super.key,
    this.result,
    this.imageFile,
    this.source = 'ocr',
    this.existingExpenses,
  }) : assert(
         result != null || existingExpenses != null,
         'Either result or existingExpenses must be provided',
       );

  @override
  State<ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<ReceiptReviewScreen> {
  late final TextEditingController _vendorCtrl;
  late final TextEditingController _notesCtrl;
  late DateTime _date;
  late List<_EditableItem> _items;
  String? _selectedCategoryId;
  String _selectedCategoryName = 'Others';
  bool _saving = false;
  int _selectedTab = 0;
  /// Edit mode only: the previously-uploaded receipt photo's public URL, if
  /// one was saved for this batch (see Supabase Storage "receipts" bucket).
  String? _savedImageUrl;

  static const _tabs = [
    'Receipt Review',
    'Voice Input',
    'Gallery',
    'Receipt History',
    'Success',
  ];

  bool get _isEditMode => widget.existingExpenses != null;
  /// The record's true origin regardless of mode — for a fresh scan this is
  /// `widget.source`, but for edit mode it must come from the saved row
  /// itself (`widget.source` is meaningless there), otherwise a reopened
  /// voice entry would wrongly display as a generic "no photo" receipt.
  late final String _originalSource;
  bool get _isVoice => _originalSource == 'voice';

  @override
  void initState() {
    super.initState();
    final existing = widget.existingExpenses;
    if (existing != null && existing.isNotEmpty) {
      final first = existing.first;
      _originalSource = first.source;
      _vendorCtrl = TextEditingController(text: first.merchantName ?? '');
      _date = first.date;
      _savedImageUrl = first.receiptImageUrl;
      // Category was saved directly as this app's local category id — no
      // name-based resolution needed the way the fresh-OCR path requires.
      _selectedCategoryId = first.categoryId;

      String sharedNotes = '';
      _items = existing.map((e) {
        final parsed = _parseSavedDescription(e.description);
        if (sharedNotes.isEmpty) sharedNotes = parsed.notes;
        return _EditableItem(
          nameCtrl: TextEditingController(text: parsed.name),
          priceCtrl: TextEditingController(text: e.amount.toStringAsFixed(2)),
          qtyCtrl: TextEditingController(text: '${parsed.quantity}'),
          originalId: e.id,
        );
      }).toList();
      _notesCtrl = TextEditingController(text: sharedNotes);
      return;
    }

    final result = widget.result!;
    _originalSource = widget.source;
    _vendorCtrl = TextEditingController(text: result.vendorName ?? '');
    _notesCtrl = TextEditingController();
    _date = result.date != null
        ? DateTime.tryParse(result.date!) ?? DateTime.now()
        : DateTime.now();
    // The backend's suggestedCategoryId is a Supabase UUID from a separate
    // categories table — it never matches this app's local slug-style category
    // ids (e.g. "shopping"), so it must not be used directly here. Only the
    // name is trustworthy; the id gets resolved locally by name below.
    _selectedCategoryName = result.suggestedCategoryName ?? 'Others';

    if (result.lineItems.isNotEmpty) {
      _items = result.lineItems
          .map(
            (li) => _EditableItem(
              nameCtrl: TextEditingController(text: li.itemName),
              priceCtrl: TextEditingController(
                text: li.price.toStringAsFixed(2),
              ),
              qtyCtrl: TextEditingController(text: '${li.quantity}'),
            ),
          )
          .toList();
    } else {
      _items = [
        _EditableItem(
          nameCtrl: TextEditingController(text: result.vendorName ?? 'Receipt'),
          priceCtrl: TextEditingController(
            text: (result.amount ?? 0.0).toStringAsFixed(2),
          ),
        ),
      ];
    }
  }

  /// Reverses the "x$qty $name · $notes" format `_save()` writes into
  /// ExpenseModel.description, so a saved record can be re-populated back
  /// into editable item/qty/notes fields.
  static ({String name, int quantity, String notes}) _parseSavedDescription(
    String description,
  ) {
    final parts = description.split(' · ');
    final itemPart = parts.first;
    final notes = parts.length > 1 ? parts.sublist(1).join(' · ') : '';

    final qtyMatch = RegExp(r'^x(\d+)\s+(.*)$').firstMatch(itemPart);
    if (qtyMatch != null) {
      return (
        name: qtyMatch.group(2)!,
        quantity: int.tryParse(qtyMatch.group(1)!) ?? 1,
        notes: notes,
      );
    }
    return (name: itemPart, quantity: 1, notes: notes);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final cats = context.read<BudgetProvider>().categories;
    if (cats.isEmpty) return;

    if (_selectedCategoryId == null) {
      final match = cats
          .where(
            (c) => c.name.toLowerCase() == _selectedCategoryName.toLowerCase(),
          )
          .firstOrNull;
      if (match != null) {
        setState(() => _selectedCategoryId = match.id);
      }
    } else {
      // Edit mode sets the id directly (see initState) — resolve its
      // display name once categories are available, for the emoji/label
      // shown in "AI Extracted Fields" and the budget-remaining line.
      final match = cats.where((c) => c.id == _selectedCategoryId).firstOrNull;
      if (match != null && match.name != _selectedCategoryName) {
        setState(() => _selectedCategoryName = match.name);
      }
    }
  }

  @override
  void dispose() {
    _vendorCtrl.dispose();
    _notesCtrl.dispose();
    for (final item in _items) {
      item.nameCtrl.dispose();
      item.priceCtrl.dispose();
      item.qtyCtrl.dispose();
    }
    super.dispose();
  }

  double get _total =>
      _items.fold(0.0, (s, i) => s + (double.tryParse(i.priceCtrl.text) ?? 0));

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final categories = context.read<BudgetProvider>().categories;

      final catId =
          _selectedCategoryId ??
          categories
              .firstWhere(
                (c) => c.name == 'Others',
                orElse: () => categories.first,
              )
              .id;
      final notes = _notesCtrl.text.trim();
      final vendor = _vendorCtrl.text.trim();

      if (_isEditMode) {
        await _saveEdits(catId: catId, notes: notes, vendor: vendor);
        if (mounted) {
          // Recompute budgets against the just-edited expense so the success
          // screen's "spent/left" reflects reality, not the pre-edit figures.
          final expenseProvider = context.read<ExpenseProvider>();
          final bp = context.read<BudgetProvider>();
          final now = DateTime.now();
          bp.recalculate(expenseProvider.expensesForMonth(now.month, now.year));
          final budgetStatus =
              bp.statuses.where((s) => s.budget.categoryId == catId).firstOrNull;

          await Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => ReceiptSuccessScreen(
                isEdit: true,
                merchantName: vendor,
                amount: _total,
                categoryName: _selectedCategoryName,
                categoryIcon: _categoryEmoji(_selectedCategoryName),
                date: _date,
                method: _saveMethodLabel,
                budgetStatus: budgetStatus,
              ),
            ),
          );
        }
      } else {
        await _saveNewScan(catId: catId, notes: notes, vendor: vendor);
        if (mounted) {
          // Recompute budgets against the just-saved expense so the success
          // screen's "spent/left" reflects reality, not the pre-save figures.
          final expenseProvider = context.read<ExpenseProvider>();
          final bp = context.read<BudgetProvider>();
          final now = DateTime.now();
          bp.recalculate(expenseProvider.expensesForMonth(now.month, now.year));
          final budgetStatus =
              bp.statuses.where((s) => s.budget.categoryId == catId).firstOrNull;

          await Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => ReceiptSuccessScreen(
                merchantName: vendor,
                amount: _total,
                categoryName: _selectedCategoryName,
                categoryIcon: _categoryEmoji(_selectedCategoryName),
                date: _date,
                method: _saveMethodLabel,
                budgetStatus: budgetStatus,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: AppColors.budgetRed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _describeItem(_EditableItem item, int qty, String notes) => [
    if (qty > 1)
      'x$qty ${item.nameCtrl.text.trim()}'
    else
      item.nameCtrl.text.trim(),
    if (notes.isNotEmpty) notes,
  ].join(' · ');

  Future<void> _saveNewScan({
    required String catId,
    required String notes,
    required String vendor,
  }) async {
    final auth = context.read<AuthProvider>();
    final uid = auth.userId;
    final expenseProvider = context.read<ExpenseProvider>();
    final db = SupabaseService.instance;
    String? firstExpenseId;
    // One id shared by every line item from this scan, so Receipt History
    // can group them back into a single row instead of one per item.
    final batchId = const Uuid().v4();

    // Best-effort: upload the receipt photo so it can be viewed again later
    // from Receipt History. Guests aren't authenticated with Supabase (no
    // Storage access), and a failed upload must never block saving the
    // actual expense data — the record is still useful without its photo.
    String? imageUrl;
    if (auth.isLoggedIn && widget.imageFile != null) {
      try {
        imageUrl = await db.uploadReceiptImage(
          File(widget.imageFile!.path),
          batchId,
        );
      } catch (e) {
        debugPrint('Receipt image upload failed: $e');
        imageUrl = null;
      }
    }

    for (final item in _items) {
      final price = double.tryParse(item.priceCtrl.text) ?? 0;
      if (price <= 0) continue;
      final qty = int.tryParse(item.qtyCtrl.text) ?? 1;

      // Goes through the same local-storage-first pipeline every other
      // screen uses — writing straight to Supabase here (as before) left
      // the record orphaned from the app's own Transactions/Budget views,
      // which read from local storage.
      final saved = await expenseProvider.addExpense(
        userId: uid,
        categoryId: catId,
        amount: price,
        description: _describeItem(item, qty, notes),
        date: _date,
        source: widget.source,
        merchantName: vendor,
        batchId: batchId,
        receiptImageUrl: imageUrl,
      );
      firstExpenseId ??= saved.id;
    }

    final w = widget.result?.warranty;
    if (w != null && w.hasWarranty && firstExpenseId != null) {
      await db.insertWarranty(
        expenseId: firstExpenseId,
        vendorName: vendor,
        durationMonths: w.durationMonths,
        expiryDate: w.expiryDate,
        status: w.status,
      );
    }
  }

  /// Edit mode: updates rows that still exist, inserts any newly added rows
  /// under the same batch, and deletes rows the user removed or zeroed out.
  Future<void> _saveEdits({
    required String catId,
    required String notes,
    required String vendor,
  }) async {
    final uid = context.read<AuthProvider>().userId;
    final expenseProvider = context.read<ExpenseProvider>();
    final original = widget.existingExpenses!;
    final batchId = original.first.batchId ?? original.first.id;
    final presentOriginalIds = <String>{};

    for (final item in _items) {
      final price = double.tryParse(item.priceCtrl.text) ?? 0;
      if (price <= 0) continue;
      final qty = int.tryParse(item.qtyCtrl.text) ?? 1;
      final desc = _describeItem(item, qty, notes);

      if (item.originalId != null) {
        presentOriginalIds.add(item.originalId!);
        final base = original.firstWhere((e) => e.id == item.originalId);
        await expenseProvider.updateExpense(
          base.copyWith(
            categoryId: catId,
            amount: price,
            description: desc,
            date: _date,
            merchantName: vendor,
          ),
        );
      } else {
        await expenseProvider.addExpense(
          userId: uid,
          categoryId: catId,
          amount: price,
          description: desc,
          date: _date,
          source: original.first.source,
          merchantName: vendor,
          batchId: batchId,
          receiptImageUrl: _savedImageUrl,
        );
      }
    }

    // Anything from the original batch no longer represented in the edited
    // list — removed via the trash icon, or zeroed out — is deleted for real.
    for (final e in original) {
      if (!presentOriginalIds.contains(e.id)) {
        await expenseProvider.deleteExpense(e.id);
      }
    }
  }

  bool get _isPdf =>
      widget.imageFile != null &&
      widget.imageFile!.path.toLowerCase().endsWith('.pdf');
  bool get _savedImageIsPdf =>
      _savedImageUrl?.toLowerCase().endsWith('.pdf') ?? false;

  String get _saveMethodLabel {
    if (_isVoice) return 'Voice Input';
    if (_isPdf) return 'PDF Upload';
    return 'Receipt Scan';
  }

  void _showFullImage() {
    if (widget.imageFile == null && _savedImageUrl == null) return;
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            if (widget.imageFile != null)
              _isPdf
                  ? PdfView(
                      controller: PdfController(
                        document: PdfDocument.openFile(widget.imageFile!.path),
                      ),
                    )
                  : InteractiveViewer(
                      child: Image.file(File(widget.imageFile!.path)),
                    )
            else if (_savedImageIsPdf)
              const Center(
                child: Text(
                  'In-app preview isn\'t available for saved PDF receipts.',
                  style: TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              )
            else
              InteractiveViewer(
                child: Image.network(_savedImageUrl!),
              ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  String _categoryEmoji(String cat) {
    switch (cat.toLowerCase()) {
      case 'food & dining':
        return '🍔';
      case 'transport':
        return '🚗';
      case 'shopping':
        return '🛍️';
      case 'entertainment':
        return '🎬';
      case 'health':
        return '💊';
      case 'utilities':
        return '💡';
      default:
        return '📦';
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = context.watch<BudgetProvider>().categories;
    final statuses = context.watch<BudgetProvider>().statuses;

    // Resolve category ID from name the moment categories are available
    if (_selectedCategoryId == null && categories.isNotEmpty) {
      _selectedCategoryId = categories
          .where(
            (c) => c.name.toLowerCase() == _selectedCategoryName.toLowerCase(),
          )
          .firstOrNull
          ?.id;
    }

    // Budget remaining for selected category
    BudgetStatus? budgetStatus;
    if (_selectedCategoryId != null) {
      budgetStatus = statuses
          .where((s) => s.budget.categoryId == _selectedCategoryId)
          .firstOrNull;
    }
    // In edit mode, budgetStatus.remaining already has this receipt's
    // *original* amount deducted (it's a saved expense, already counted) —
    // so plain "remaining - _total" would double-subtract it. Add back
    // whatever part of the original total was under the currently selected
    // category before subtracting the edited total. (Zero when the category
    // was changed, since none of the original amount counted against it.)
    final originalCategoryTotal = (widget.existingExpenses ?? const [])
        .where((e) => e.categoryId == _selectedCategoryId)
        .fold(0.0, (s, e) => s + e.amount);
    final remainingAfter = budgetStatus != null
        ? (budgetStatus.remaining + originalCategoryTotal - _total)
            .clamp(0.0, double.infinity)
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A5276),
        foregroundColor: Colors.white,
        title: Text(
          _isVoice
              ? (_isEditMode ? 'Edit Voice Entry' : 'Voice Entry Review')
              : (_isEditMode ? 'Edit Receipt' : 'Receipt Review'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF27AE60),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _isEditMode
                  ? (_isVoice ? 'Saved Voice Entry' : 'Saved Receipt')
                  : 'AI Processed',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Tab bar ────────────────────────────────────────────────
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(_tabs.length, (i) {
                  final sel = i == _selectedTab;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedTab = i),
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: sel ? AppColors.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: sel
                            ? null
                            : Border.all(color: const Color(0xFFDDDDDD)),
                      ),
                      child: Text(
                        _tabs[i],
                        style: TextStyle(
                          color: sel ? Colors.white : const Color(0xFF555555),
                          fontSize: 13,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),

          // ── Scrollable content ──────────────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Receipt Image card ─────────────────────────────────
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _isVoice ? 'Voice Transcript' : 'Receipt Image',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          GestureDetector(
                            onTap: _pickDate,
                            child: Row(
                              children: [
                                Text(
                                  DateFormat(
                                    'dd MMM yyyy, h:mm a',
                                  ).format(_date),
                                  style: const TextStyle(
                                    color: Color(0xFF888888),
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.edit_calendar_outlined,
                                  size: 14,
                                  color: Color(0xFF888888),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: (widget.imageFile != null || _savedImageUrl != null)
                            ? _showFullImage
                            : null,
                        child: Container(
                          height: 130,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: const Color(0xFFCCCCCC),
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            color: const Color(0xFFF8F8F8),
                          ),
                          child: _isVoice
                              ? Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.mic_rounded,
                                        size: 32,
                                        color: Color(0xFFAAAAAA),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        widget.result?.rawText.isNotEmpty ==
                                                true
                                            ? '"${widget.result!.rawText}"'
                                            : 'No transcript captured',
                                        textAlign: TextAlign.center,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Color(0xFF555555),
                                          fontSize: 12,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : _isPdf
                              ? const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.picture_as_pdf_rounded,
                                      size: 44,
                                      color: Color(0xFFAAAAAA),
                                    ),
                                    SizedBox(height: 6),
                                    Text(
                                      'PDF receipt',
                                      style: TextStyle(
                                        color: Color(0xFF777777),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      'Tap to view full PDF',
                                      style: TextStyle(
                                        color: Color(0xFFAAAAAA),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                )
                              : widget.imageFile != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(7),
                                  child: Image.file(
                                    File(widget.imageFile!.path),
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : _savedImageUrl != null
                              ? (_savedImageIsPdf
                                    ? const Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.picture_as_pdf_rounded,
                                            size: 44,
                                            color: Color(0xFFAAAAAA),
                                          ),
                                          SizedBox(height: 6),
                                          Text(
                                            'PDF receipt',
                                            style: TextStyle(
                                              color: Color(0xFF777777),
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      )
                                    : ClipRRect(
                                        borderRadius: BorderRadius.circular(7),
                                        child: Image.network(
                                          _savedImageUrl!,
                                          fit: BoxFit.cover,
                                          loadingBuilder:
                                              (_, child, progress) =>
                                                  progress == null
                                                  ? child
                                                  : const Center(
                                                      child:
                                                          CircularProgressIndicator(),
                                                    ),
                                          errorBuilder: (_, __, ___) =>
                                              const Center(
                                                child: Icon(
                                                  Icons.broken_image_outlined,
                                                  size: 40,
                                                  color: Color(0xFFAAAAAA),
                                                ),
                                              ),
                                        ),
                                      ))
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.receipt_long_rounded,
                                      size: 44,
                                      color: Color(0xFFAAAAAA),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _isEditMode
                                          ? 'No image saved for this receipt'
                                          : 'Receipt captured',
                                      style: const TextStyle(
                                        color: Color(0xFF777777),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (!_isEditMode)
                                      const Text(
                                        'Tap to view full image',
                                        style: TextStyle(
                                          color: Color(0xFFAAAAAA),
                                          fontSize: 11,
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF27AE60),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _isEditMode
                                ? (_isVoice
                                      ? 'Editing a previously saved voice entry'
                                      : 'Editing a previously saved receipt')
                                : _isVoice
                                ? 'Transcribed from voice input'
                                : 'AI extraction complete',
                            style: const TextStyle(
                              color: Color(0xFF444444),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ── AI Extracted Fields ──────────────────────────────
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFDCEFD8)),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.layers_outlined,
                            color: Color(0xFF2E7D32),
                            size: 18,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'AI Extracted Fields',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _extractedRow(
                        'Merchant',
                        _vendorCtrl.text.isEmpty ? '—' : _vendorCtrl.text,
                        _vendorCtrl.text.isNotEmpty,
                      ),
                      _extractedRow(
                        'Date',
                        DateFormat('dd MMM yyyy').format(_date),
                        _isEditMode || widget.result?.dateConfidence != 'low',
                      ),
                      _extractedRow(
                        'Category',
                        '${_categoryEmoji(_selectedCategoryName)} $_selectedCategoryName',
                        _isEditMode ||
                            widget.result?.suggestedCategoryConfidence != 'low',
                      ),
                      _extractedRow(
                        'Total',
                        'RM ${(widget.result?.amount ?? _total).toStringAsFixed(2)}',
                        widget.result?.amount != null || _isEditMode,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ── Line Items table ─────────────────────────────────
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Line Items',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.add, size: 14),
                            label: const Text(
                              'Add Row',
                              style: TextStyle(fontSize: 12),
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.primary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 0,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => setState(
                              () => _items.add(
                                _EditableItem(
                                  nameCtrl: TextEditingController(),
                                  priceCtrl: TextEditingController(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      // Header
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Color(0xFFEEEEEE)),
                          ),
                        ),
                        child: const Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Text(
                                'ITEM',
                                style: TextStyle(
                                  color: Color(0xFF888888),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            SizedBox(
                              width: 40,
                              child: Text(
                                'QTY',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF888888),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: Text(
                                'PRICE',
                                style: TextStyle(
                                  color: Color(0xFF888888),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            SizedBox(width: 4),
                            SizedBox(width: 24),
                          ],
                        ),
                      ),
                      // Item rows
                      for (int i = 0; i < _items.length; i++) ...[
                        _ItemRow(
                          item: _items[i],
                          onDelete: _items.length > 1
                              ? () => setState(() {
                                  _items[i].nameCtrl.dispose();
                                  _items[i].priceCtrl.dispose();
                                  _items[i].qtyCtrl.dispose();
                                  _items.removeAt(i);
                                })
                              : null,
                          onChanged: () => setState(() {}),
                        ),
                        if (i < _items.length - 1)
                          const Divider(height: 1, color: Color(0xFFF0F0F0)),
                      ],
                      // Total row
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: const BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Color(0xFFEEEEEE)),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              flex: 3,
                              child: Text(
                                'Total',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const SizedBox(width: 40),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: Text(
                                'RM ${(widget.result?.amount ?? _total).toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: Color(0xFF1A5276),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const SizedBox(width: 24),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ── Merchant name ────────────────────────────────────
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Merchant name',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _vendorCtrl,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'e.g. Jaya Grocer, Mid Valley',
                          hintStyle: const TextStyle(
                            color: Color(0xFFAAAAAA),
                            fontSize: 13,
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF8F9FA),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFE0E0E0),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFE0E0E0),
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ── Category chips ───────────────────────────────────
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Category',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (categories.isEmpty)
                        const Text(
                          'Log in to see categories',
                          style: TextStyle(
                            color: Color(0xFF888888),
                            fontSize: 13,
                          ),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: categories.map((cat) {
                            final selected = _selectedCategoryId != null
                                ? cat.id == _selectedCategoryId
                                : cat.name.toLowerCase() ==
                                      _selectedCategoryName.toLowerCase();
                            final emoji = _categoryEmoji(cat.name);
                            return GestureDetector(
                              onTap: () => setState(() {
                                _selectedCategoryId = cat.id;
                                _selectedCategoryName = cat.name;
                              }),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFF1B4332)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: selected
                                        ? const Color(0xFF1B4332)
                                        : const Color(0xFFDDDDDD),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      emoji,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      cat.name,
                                      style: TextStyle(
                                        color: selected
                                            ? Colors.white
                                            : const Color(0xFF333333),
                                        fontSize: 13,
                                        fontWeight: selected
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ── Notes ────────────────────────────────────────────
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Text(
                            'Notes',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          SizedBox(width: 4),
                          Text(
                            '(optional)',
                            style: TextStyle(
                              color: Color(0xFF888888),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _notesCtrl,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'e.g. Weekly groceries',
                          hintStyle: const TextStyle(
                            color: Color(0xFFAAAAAA),
                            fontSize: 13,
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF8F9FA),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFE0E0E0),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFE0E0E0),
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Budget remaining ─────────────────────────────────
                if (remainingAfter != null) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$_selectedCategoryName budget after saving',
                          style: const TextStyle(
                            color: Color(0xFF555555),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'RM ${remainingAfter.toStringAsFixed(2)} remaining',
                          style: TextStyle(
                            color: remainingAfter < 50
                                ? AppColors.budgetRed
                                : const Color(0xFF27AE60),
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // ── Warranty card ─────────────────────────────────────
                if (widget.result?.warranty != null) ...[
                  const SizedBox(height: 12),
                  _warrantyCard(widget.result!.warranty!),
                ],

                const SizedBox(height: 24),

                // ── Save button ───────────────────────────────────────
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B4332),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 2,
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _isEditMode
                              ? 'Save Changes'
                              : 'Confirm & Save Expense',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
    ),
    padding: const EdgeInsets.all(16),
    child: child,
  );

  Widget _extractedRow(String label, String value, bool high) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF888888), fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: high ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            high ? 'HIGH' : 'LOW',
            style: TextStyle(
              color: high ? const Color(0xFF2E7D32) : const Color(0xFFE65100),
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _warrantyCard(WarrantyInfo w) {
    Color bg, fg;
    String statusLabel;
    IconData icon;
    switch (w.status) {
      case 'green':
        bg = AppColors.alertGreenBg;
        fg = AppColors.budgetGreen;
        statusLabel = 'Valid';
        icon = Icons.verified_rounded;
        break;
      case 'yellow':
        bg = AppColors.alertYellowBg;
        fg = AppColors.budgetYellow;
        statusLabel = 'Expiring Soon';
        icon = Icons.warning_amber_rounded;
        break;
      case 'red':
        bg = AppColors.alertRedBg;
        fg = AppColors.budgetRed;
        statusLabel = 'Expired';
        icon = Icons.cancel_rounded;
        break;
      default:
        bg = AppColors.primarySurface;
        fg = AppColors.primary;
        statusLabel = 'Warranty Detected';
        icon = Icons.shield_rounded;
    }
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Warranty $statusLabel',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: fg,
                    fontSize: 14,
                  ),
                ),
                if (w.durationMonths != null)
                  Text(
                    'Duration: ${w.durationMonths} month(s)',
                    style: TextStyle(color: fg, fontSize: 12),
                  ),
                if (w.expiryDate != null)
                  Text(
                    'Expires: ${w.expiryDate}',
                    style: TextStyle(color: fg, fontSize: 12),
                  ),
                if (w.daysRemaining != null && w.daysRemaining! >= 0)
                  Text(
                    '${w.daysRemaining} day(s) remaining',
                    style: TextStyle(color: fg, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Models ─────────────────────────────────────────────────────────────────────

class _EditableItem {
  TextEditingController nameCtrl;
  TextEditingController priceCtrl;
  TextEditingController qtyCtrl;

  /// Set when this row was loaded from an already-saved ExpenseModel (edit
  /// mode) — null for a freshly-scanned or manually added row.
  final String? originalId;

  _EditableItem({
    required this.nameCtrl,
    required this.priceCtrl,
    TextEditingController? qtyCtrl,
    this.originalId,
  }) : qtyCtrl = qtyCtrl ?? TextEditingController(text: '1');
}

// ── Item row ───────────────────────────────────────────────────────────────────

class _ItemRow extends StatelessWidget {
  final _EditableItem item;
  final VoidCallback? onDelete;
  final VoidCallback onChanged;

  const _ItemRow({
    required this.item,
    required this.onDelete,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextFormField(
              controller: item.nameCtrl,
              onChanged: (_) => onChanged(),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                border: OutlineInputBorder(),
                hintText: 'Item name',
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            child: TextFormField(
              controller: item.qtyCtrl,
              onChanged: (_) => onChanged(),
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 6,
                ),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              controller: item.priceCtrl,
              onChanged: (_) => onChanged(),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                border: OutlineInputBorder(),
                prefixText: 'RM ',
                prefixStyle: TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 24,
            child: onDelete != null
                ? GestureDetector(
                    onTap: onDelete,
                    child: const Icon(
                      Icons.remove_circle_outline,
                      color: Color(0xFFE74C3C),
                      size: 20,
                    ),
                  )
                : const SizedBox(),
          ),
        ],
      ),
    );
  }
}
