import 'package:flutter/material.dart';
import '../../domain/exercises/exercise_answer_method.dart';

/// Interactive UI widget presenting multiple-choice recognition options.
class MultipleChoiceCard extends StatelessWidget {
  final MultipleChoiceAnswerMethod answerMethod;
  final bool hasAnswered;
  final int? selectedIndex;
  final void Function(int selectedIndex, bool isCorrect) onOptionSelected;

  const MultipleChoiceCard({
    super.key,
    required this.answerMethod,
    required this.hasAnswered,
    required this.selectedIndex,
    required this.onOptionSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCorrect = selectedIndex == answerMethod.correctOptionIndex;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...List.generate(answerMethod.options.length, (index) {
            final optionText = answerMethod.options[index];
            final isThisOption = selectedIndex == index;
            final isTarget = index == answerMethod.correctOptionIndex;

            Color? buttonColor;
            Color? textColor;
            IconData? trailingIcon;

            if (hasAnswered) {
              if (isTarget) {
                buttonColor = const Color(0xFF2E7D32).withValues(alpha: 0.18);
                textColor = const Color(0xFF1B5E20);
                trailingIcon = Icons.check_circle;
              } else if (isThisOption && !isCorrect) {
                buttonColor = const Color(0xFFC62828).withValues(alpha: 0.18);
                textColor = const Color(0xFFB71C1C);
                trailingIcon = Icons.cancel;
              } else {
                textColor = theme.colorScheme.onSurface.withValues(alpha: 0.4);
              }
            }

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                height: 58,
                child: OutlinedButton(
                  key: Key('option_button_$index'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: buttonColor,
                    side: BorderSide(
                      color: hasAnswered && isTarget
                          ? const Color(0xFF2E7D32)
                          : (hasAnswered && isThisOption && !isCorrect
                              ? const Color(0xFFC62828)
                              : theme.colorScheme.outlineVariant),
                      width: hasAnswered && (isTarget || isThisOption) ? 2.0 : 1.0,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: hasAnswered
                      ? null
                      : () {
                          onOptionSelected(index, index == answerMethod.correctOptionIndex);
                        },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          optionText,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: textColor ?? theme.colorScheme.onSurface,
                            fontWeight: isTarget || isThisOption
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (trailingIcon != null)
                        Icon(trailingIcon, color: textColor, size: 22),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
          if (hasAnswered && answerMethod.explanation != null)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isCorrect
                    ? const Color(0xFF2E7D32).withValues(alpha: 0.12)
                    : const Color(0xFFC62828).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isCorrect
                      ? const Color(0xFF2E7D32).withValues(alpha: 0.3)
                      : const Color(0xFFC62828).withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isCorrect ? Icons.check_circle_outline : Icons.info_outline,
                    color: isCorrect ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      answerMethod.explanation!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isCorrect
                            ? const Color(0xFF1B5E20)
                            : const Color(0xFFB71C1C),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
