class AppFontOption {
  const AppFontOption({
    required this.id,
    required this.label,
    required this.mood,
  });

  final String id;
  final String label;
  final String mood;
}

class AppFonts {
  const AppFonts._();

  static const String defaultFamily = 'Inter';

  static const List<AppFontOption> catalog = [
    AppFontOption(id: 'Inter', label: 'Inter', mood: 'Clean utility · default'),
    AppFontOption(id: 'Poppins', label: 'Poppins', mood: 'Friendly and rounded'),
    AppFontOption(id: 'Nunito', label: 'Nunito', mood: 'Soft and welcoming'),
    AppFontOption(id: 'Outfit', label: 'Outfit', mood: 'Modern geometric'),
    AppFontOption(id: 'Manrope', label: 'Manrope', mood: 'Calm and precise'),
    AppFontOption(id: 'Plus Jakarta Sans', label: 'Plus Jakarta Sans', mood: 'Editorial product'),
    AppFontOption(id: 'DM Sans', label: 'DM Sans', mood: 'Crisp interface'),
    AppFontOption(id: 'Urbanist', label: 'Urbanist', mood: 'Contemporary display'),
    AppFontOption(id: 'Figtree', label: 'Figtree', mood: 'Warm grotesque'),
    AppFontOption(id: 'Lexend', label: 'Lexend', mood: 'High readability'),
    AppFontOption(id: 'Space Grotesk', label: 'Space Grotesk', mood: 'Technical and bold'),
    AppFontOption(id: 'Work Sans', label: 'Work Sans', mood: 'Neutral workhorse'),
    AppFontOption(id: 'Source Sans 3', label: 'Source Sans 3', mood: 'Classic screen type'),
    AppFontOption(id: 'Rubik', label: 'Rubik', mood: 'Slightly playful'),
    AppFontOption(id: 'Mulish', label: 'Mulish', mood: 'Balanced body text'),
    AppFontOption(id: 'Karla', label: 'Karla', mood: 'Honest and simple'),
    AppFontOption(id: 'IBM Plex Sans', label: 'IBM Plex Sans', mood: 'Engineered clarity'),
    AppFontOption(id: 'Sora', label: 'Sora', mood: 'Airy and premium'),
    AppFontOption(id: 'Be Vietnam Pro', label: 'Be Vietnam Pro', mood: 'Sharp and stylish'),
    AppFontOption(id: 'Public Sans', label: 'Public Sans', mood: 'Civic and trustworthy'),
  ];

  static AppFontOption byId(String? id) {
    return catalog.firstWhere(
      (item) => item.id == id,
      orElse: () => catalog.first,
    );
  }
}
