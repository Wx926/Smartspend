class WarrantyInfo {
  final bool hasWarranty;
  final int? durationMonths;
  final String? expiryDate;
  final String status; // green | yellow | red | unknown
  final int? daysRemaining;

  const WarrantyInfo({
    required this.hasWarranty,
    this.durationMonths,
    this.expiryDate,
    required this.status,
    this.daysRemaining,
  });

  factory WarrantyInfo.fromJson(Map<String, dynamic> json) => WarrantyInfo(
        hasWarranty: json['has_warranty'] as bool? ?? false,
        durationMonths: json['duration_months'] as int?,
        expiryDate: json['expiry_date'] as String?,
        status: json['status'] as String? ?? 'unknown',
        daysRemaining: json['days_remaining'] as int?,
      );
}

class OcrLineItem {
  String itemName;
  double price;
  int quantity;
  String? categoryId;
  String categoryName;

  OcrLineItem({
    required this.itemName,
    required this.price,
    this.quantity = 1,
    this.categoryId,
    required this.categoryName,
  });

  factory OcrLineItem.fromJson(Map<String, dynamic> json) => OcrLineItem(
        itemName: json['item_name'] as String? ?? '',
        price: (json['price'] as num?)?.toDouble() ?? 0.0,
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
        categoryId: json['category_id'] as String?,
        categoryName: json['category_name'] as String? ?? 'Others',
      );
}

class OcrResult {
  String? vendorName;
  double? amount;
  String? date;
  final String rawText;
  List<OcrLineItem> lineItems;
  String? suggestedCategoryId;
  String? suggestedCategoryName;
  String? suggestedCategoryConfidence; // "high" | "low"
  String? dateConfidence; // "high" | "low"
  WarrantyInfo? warranty;

  OcrResult({
    this.vendorName,
    this.amount,
    this.date,
    required this.rawText,
    required this.lineItems,
    this.suggestedCategoryId,
    this.suggestedCategoryName,
    this.suggestedCategoryConfidence,
    this.dateConfidence,
    this.warranty,
  });

  factory OcrResult.fromJson(Map<String, dynamic> json) {
    final warrantyJson = json['warranty'] as Map<String, dynamic>?;
    final itemsJson =
        (json['line_items'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    return OcrResult(
      vendorName: json['vendor_name'] as String?,
      amount: (json['amount'] as num?)?.toDouble(),
      date: json['date'] as String?,
      rawText: json['raw_text'] as String? ?? '',
      lineItems: itemsJson.map(OcrLineItem.fromJson).toList(),
      suggestedCategoryId: json['suggested_category_id'] as String?,
      suggestedCategoryName: json['suggested_category_name'] as String?,
      suggestedCategoryConfidence: json['suggested_category_confidence'] as String?,
      dateConfidence: json['date_confidence'] as String?,
      warranty: warrantyJson != null ? WarrantyInfo.fromJson(warrantyJson) : null,
    );
  }
}
