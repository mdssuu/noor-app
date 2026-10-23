import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../main.dart' show NoorColors;

// ===========================================================================
//  THE ADMIN PANEL'S CONTROL KIT
//
//  One set of building blocks for every screen that only the app's owner
//  should reach — the panel itself and the remote-config editor it opens.
//  They are shared rather than copied so that a control the owner learns to
//  read in one place behaves, looks and *means* the same in the other.
// ===========================================================================

/// The small gold caption above a control, naming what it decides.
Widget adminLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text,
        style: GoogleFonts.outfit(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: NoorColors.onGlassGold,
          letterSpacing: 0.3,
        ),
      ),
    );

/// A dropdown dressed for the sky it sits on: dark list, green field, gold
/// border that turns emerald under the finger.
///
/// [value] is passed as `initialValue` because these screens hold their own
/// copy of what is being edited — a form the owner has not saved yet must not
/// snap back to whatever the document currently says.
Widget adminDropdown<T>({
  required T value,
  required List<DropdownMenuItem<T>> items,
  required ValueChanged<T?> onChanged,
}) {
  return DropdownButtonFormField<T>(
    initialValue: value,
    isExpanded: true,
    dropdownColor: NoorColors.white,
    style: GoogleFonts.outfit(fontSize: 13, color: NoorColors.ink),
    decoration: InputDecoration(
      filled: true,
      fillColor: NoorColors.cardGreen,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(color: NoorColors.gold.withValues(alpha: 0.6)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(color: NoorColors.gold.withValues(alpha: 0.6)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: NoorColors.emerald, width: 1.4),
      ),
    ),
    items: items,
    onChanged: onChanged,
  );
}

/// A two-way choice — Hanafi/Shafi, 12/24 — drawn as one pill rather than a
/// dropdown, because a dropdown with two entries is a menu pretending to be
/// a decision.
Widget adminSegmented<T>({
  required T value,
  required List<MapEntry<T, String>> options,
  required ValueChanged<T> onChanged,
}) {
  return Row(
    children: options.map((MapEntry<T, String> option) {
      final bool selected = option.key == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(option.key),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: selected ? NoorColors.emerald : NoorColors.cardGreen,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: selected
                    ? NoorColors.emerald
                    : NoorColors.gold.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              option.value,
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? NoorColors.ink : NoorColors.muted,
              ),
            ),
          ),
        ),
      );
    }).toList(),
  );
}
