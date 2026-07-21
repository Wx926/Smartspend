import 'package:flutter/material.dart';
import '../../../shared/theme/app_colors.dart';

/// Shared 4-dot indicator + numeric keypad used by every passcode screen
/// (initial setup, verification before a reset, and the app lock screen).
class PasscodeKeypad extends StatelessWidget {
  final int enteredLength;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final Color dotColor;
  final Color keyColor;

  const PasscodeKeypad({
    super.key,
    required this.enteredLength,
    required this.onDigit,
    required this.onBackspace,
    this.dotColor = AppColors.primary,
    this.keyColor = AppColors.textPrimary,
  });

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', '⌫'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(4, (i) {
            final filled = i < enteredLength;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? dotColor : Colors.transparent,
                border: Border.all(color: dotColor, width: 2),
              ),
            );
          }),
        ),
        const SizedBox(height: 32),
        for (final row in _rows)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.map(_key).toList(),
          ),
      ],
    );
  }

  Widget _key(String k) {
    if (k.isEmpty) {
      return const SizedBox(width: 72, height: 72);
    }
    final isBackspace = k == '⌫';
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: isBackspace ? onBackspace : () => onDigit(k),
          child: SizedBox(
            width: 72,
            height: 72,
            child: Center(
              child: isBackspace
                  ? Icon(Icons.backspace_outlined, color: keyColor)
                  : Text(
                      k,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        color: keyColor,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
